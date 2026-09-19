#include "Switch2KitWinRT.h"
#include "BoundedQueue.hpp"
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Storage.Streams.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <memory>
#include <thread>
#include <unordered_map>
#include <vector>

using namespace winrt;
using namespace Windows::Foundation;
using namespace Windows::Devices::Bluetooth;
using namespace Windows::Devices::Bluetooth::Advertisement;
using namespace Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace Windows::Devices::Radios;
using namespace Windows::Storage::Streams;

namespace {
template<class F> void quietly(F&& f) noexcept { try { f(); } catch (...) {} }
struct Characteristic {
    GattCharacteristic value{nullptr};
    event_token changed{};
    bool registered = false;
    bool notifying = false;
};
struct Link {
    BluetoothLEDevice device{nullptr};
    GattSession session{nullptr};
    std::vector<GattDeviceService> services;
    std::vector<Characteristic> characteristics;
    std::unordered_map<uint64_t, IAsyncInfo> operations;
    event_token disconnected{}, invalidated{}, mtu{};
    bool deviceEvents = false, sessionEvents = false, ready = false, discovering = false, writing = false;
    ~Link() { close(); }
    void close() noexcept {
        ready = false;
        for (auto& entry : operations) quietly([&] { entry.second.Cancel(); });
        operations.clear();
        for (auto& ch : characteristics)
            if (ch.registered) quietly([&] { ch.value.ValueChanged(ch.changed); });
        characteristics.clear();
        if (device && deviceEvents) {
            quietly([&] { device.ConnectionStatusChanged(disconnected); });
            quietly([&] { device.GattServicesChanged(invalidated); });
        }
        deviceEvents = false;
        if (session) {
            if (sessionEvents) quietly([&] { session.MaxPduSizeChanged(mtu); });
            quietly([&] { session.MaintainConnection(false); });
            quietly([&] { session.Close(); });
        }
        sessionEvents = false;
        session = nullptr;
        for (auto& service : services) quietly([&] { service.Close(); });
        services.clear();
        if (device) quietly([&] { device.Close(); });
        device = nullptr;
    }
};

// One MTA thread owns every WinRT object. WinRT callbacks only submit bounded
// work to that thread. No async operation blocks the emulator/Swift radio queue.
struct Core : std::enable_shared_from_this<Core> {
    using Task = std::function<void(Core&)>;
    Switch2KitWinRT::BoundedQueue<Task, 256> tasks;
    Switch2KitWinRT::BoundedQueue<S2WEvent, 512> events;
    std::mutex wakeMutex;
    std::condition_variable wake;
    std::atomic<bool> stopping{false}, faulted{false};
    std::thread worker;
    uint64_t epoch = 1, nextOperation = 0, host = 0;
    BluetoothLEAdvertisementWatcher watcher{nullptr};
    Radio radio{nullptr};
    event_token received{}, watcherStopped{}, radioChanged{};
    bool watcherEvents = false, radioEvents = false, scanning = false;
    int32_t state = 0;
    IAsyncInfo startup{nullptr};
    std::unordered_map<uint64_t, std::unique_ptr<Link>> links;

    bool post(Task task) {
        std::lock_guard<std::mutex> lock(wakeMutex);
        if (stopping.load()) return false;
        if (!tasks.push(std::move(task))) { faulted.store(true); wake.notify_one(); return false; }
        wake.notify_one(); return true;
    }
    void emit(S2WEvent event) {
        if (!events.push(event) && event.kind != S2W_ADVERTISEMENT) {
            // Failure is observable, and the worker closes all affected links.
            // Never silently overwrite a button release, ACK or stop request.
            std::lock_guard<std::mutex> lock(wakeMutex);
            faulted.store(true); wake.notify_one();
        }
    }
    S2WEvent event(uint32_t kind, uint64_t token = 0) {
        S2WEvent value{}; value.kind = kind; value.token = token; return value;
    }
    void publishState(int32_t value) {
        state = value;
        auto result = event(S2W_STATE); result.status = value; result.host_address = host; emit(result);
    }
    void fail(uint64_t token, int32_t status) {
        if (token) {
            auto i = links.find(token);
            if (i == links.end()) return;
            links.erase(i);
            auto result = event(S2W_FAILED, token); result.status = status; emit(result);
        } else {
            cleanup();
            publishState(status == E_ACCESSDENIED ? 3 : 2);
        }
    }
    template<class Operation, class F> void after(Operation operation, uint64_t token, F completion) {
        auto operationID = ++nextOperation;
        if (token) {
            auto i = links.find(token);
            if (i == links.end()) { quietly([&] { operation.Cancel(); }); return; }
            if (i->second->operations.size() >= 16) { fail(token, E_OUTOFMEMORY); return; }
            i->second->operations.emplace(operationID, operation.template as<IAsyncInfo>());
        } else startup = operation.template as<IAsyncInfo>();
        auto weak = weak_from_this();
        auto generation = epoch;
        operation.Completed([weak, generation, token, operationID, completion](auto const& done, AsyncStatus) {
            if (auto owner = weak.lock()) owner->post([=](Core& self) {
                if (generation != self.epoch) return;
                if (token) {
                    auto i = self.links.find(token);
                    if (i == self.links.end()) return;
                    i->second->operations.erase(operationID);
                } else self.startup = nullptr;
                try { completion(self, done.GetResults()); }
                catch (hresult_error const& error) { self.fail(token, error.code()); }
                catch (...) { self.fail(token, E_FAIL); }
            });
        });
    }
    void cleanup() noexcept {
        ++epoch;
        scanning = false;
        if (startup) quietly([&] { startup.Cancel(); });
        startup = nullptr;
        if (watcher) {
            if (watcherEvents) {
                quietly([&] { watcher.Received(received); });
                quietly([&] { watcher.Stopped(watcherStopped); });
            }
            quietly([&] { watcher.Stop(); });
        }
        watcherEvents = false; watcher = nullptr;
        if (radio && radioEvents) quietly([&] { radio.StateChanged(radioChanged); });
        radioEvents = false; radio = nullptr;
        links.clear();
    }
    void run() noexcept {
        try {
            init_apartment(apartment_type::multi_threaded);
            initialize();
            while (!stopping.load()) {
                if (faulted.exchange(false)) {
                    cleanup(); tasks.clear(); events.clear();
                    emit(event(S2W_OVERFLOW));
                    publishState(1);
                    // Retry is explicit through SDK stop/start; do not reconnect
                    // automatically after losing ownership of input transitions.
                    continue;
                }
                Task task;
                if (tasks.pop(task)) {
                    try { task(*this); }
                    catch (hresult_error const& error) { fail(0, error.code()); }
                    catch (...) { fail(0, E_FAIL); }
                    continue;
                }
                std::unique_lock<std::mutex> lock(wakeMutex);
                wake.wait(lock, [&] {
                    return stopping.load() || faulted.load() || !tasks.empty();
                });
            }
            cleanup(); tasks.clear();
            uninit_apartment();
        } catch (...) { publishState(2); }
    }
    void initialize() {
        after(BluetoothAdapter::GetDefaultAsync(), 0, [](Core& self, BluetoothAdapter adapter) {
            if (!adapter || !adapter.IsLowEnergySupported()) { self.publishState(2); return; }
            self.host = adapter.BluetoothAddress();
            self.after(adapter.GetRadioAsync(), 0, [](Core& core, Radio selected) {
                if (!selected) { core.publishState(3); return; }
                core.radio = selected;
                auto weak = core.weak_from_this(); auto generation = core.epoch;
                core.radioChanged = selected.StateChanged([weak, generation](auto const&, auto const&) {
                    if (auto owner = weak.lock()) owner->post([generation](Core& c) {
                        if (c.epoch == generation) c.updateRadio();
                    });
                });
                core.radioEvents = true;
                core.updateRadio();
            });
        });
    }
    void updateRadio() {
        if (!radio) return;
        const auto value = radio.State();
        if (value != RadioState::On) {
            if (watcher) quietly([&] { watcher.Stop(); });
            scanning = false; links.clear();
        }
        publishState(value == RadioState::On ? 5 : value == RadioState::Disabled ? 3 : 4);
    }
    void scan(bool enabled) {
        if (!enabled) {
            scanning = false;
            if (watcher) watcher.Stop();
            return;
        }
        if (state != 5 || scanning) return;
        if (!watcher) {
            watcher = BluetoothLEAdvertisementWatcher();
            watcher.ScanningMode(BluetoothLEScanningMode::Active);
            auto weak = weak_from_this(); auto generation = epoch;
            received = watcher.Received([weak, generation](auto const&, BluetoothLEAdvertisementReceivedEventArgs const& args) {
                try {
                    for (auto const& manufacturer : args.Advertisement().ManufacturerData()) {
                        if (manufacturer.CompanyId() != 0x0553) continue;
                        const auto buffer = manufacturer.Data();
                        if (buffer.Length() < 16 || buffer.Length() > 510) continue;
                        S2WEvent e{}; e.kind = S2W_ADVERTISEMENT;
                        e.address = args.BluetoothAddress(); e.address_type = static_cast<uint32_t>(args.BluetoothAddressType());
                        e.rssi = args.RawSignalStrengthInDBm(); e.length = buffer.Length() + 2;
                        e.bytes[0] = 0x53; e.bytes[1] = 0x05;
                        DataReader::FromBuffer(buffer).ReadBytes(array_view<uint8_t>(e.bytes + 2, e.bytes + e.length));
                        if (auto owner = weak.lock()) owner->post([generation, e](Core& c) mutable {
                            if (c.epoch != generation || !c.scanning) return;
                            e.host_address = c.host; c.emit(e);
                        });
                        break;
                    }
                } catch (...) { /* Ignore malformed advertisements, not link input. */ }
            });
            watcherStopped = watcher.Stopped([weak, generation](auto const&, BluetoothLEAdvertisementWatcherStoppedEventArgs const& args) {
                const auto error = args.Error();
                if (auto owner = weak.lock()) owner->post([generation, error](Core& c) {
                    if (c.epoch != generation || !c.scanning || error == BluetoothError::Success) return;
                    c.fail(0, error == BluetoothError::DisabledByUser || error == BluetoothError::DisabledByPolicy ? E_ACCESSDENIED : E_FAIL);
                });
            });
            watcherEvents = true;
        }
        scanning = true; watcher.Start();
    }
    void connect(uint64_t token, uint64_t address, uint32_t type) {
        if (state != 5 || links.size() >= 64 || links.count(token)) {
            auto e = event(S2W_FAILED, token); e.status = E_FAIL; emit(e); return;
        }
        links.emplace(token, std::make_unique<Link>());
        try {
            after(BluetoothLEDevice::FromBluetoothAddressAsync(address, static_cast<BluetoothAddressType>(type)), token,
                  [token](Core& self, BluetoothLEDevice device) {
                if (!device) { self.fail(token, E_ACCESSDENIED); return; }
                auto& link = *self.links.at(token); link.device = device;
                auto weak = self.weak_from_this(); auto generation = self.epoch;
                link.disconnected = device.ConnectionStatusChanged([weak, generation, token](auto const&, auto const&) {
                    if (auto owner = weak.lock()) owner->post([generation, token](Core& c) {
                        if (c.epoch != generation || !c.links.count(token)) return;
                        auto& l = *c.links.at(token);
                        if (l.ready && l.device.ConnectionStatus() == BluetoothConnectionStatus::Disconnected) c.cancel(token);
                    });
                });
                link.invalidated = device.GattServicesChanged([weak, generation, token](auto const&, auto const&) {
                    if (auto owner = weak.lock()) owner->post([generation, token](Core& c) {
                        if (c.epoch == generation && c.links.count(token) && c.links.at(token)->ready) c.fail(token, E_CHANGED_STATE);
                    });
                });
                link.deviceEvents = true;
                self.after(GattSession::FromDeviceIdAsync(device.BluetoothDeviceId()), token,
                           [token](Core& core, GattSession session) {
                    if (!session) { core.fail(token, E_FAIL); return; }
                    auto& l = *core.links.at(token); l.session = session;
                    session.MaintainConnection(true);
                    auto weak = core.weak_from_this(); auto generation = core.epoch;
                    l.mtu = session.MaxPduSizeChanged([weak, generation, token](auto const&, auto const&) {
                        if (auto owner = weak.lock()) owner->post([generation, token](Core& c) {
                            if (c.epoch != generation || !c.links.count(token)) return;
                            auto e = c.event(S2W_MTU, token); e.flags = c.links.at(token)->session.MaxPduSize(); c.emit(e);
                        });
                    });
                    l.sessionEvents = true;
                    // A factory result is NOT a connection. Uncached discovery
                    // initiates GATT and must succeed before emitting CONNECTED.
                    core.after(l.device.GetGattServicesAsync(BluetoothCacheMode::Uncached), token,
                               [token](Core& c, GattDeviceServicesResult result) {
                        if (result.Status() != GattCommunicationStatus::Success || result.Services().Size() > 32) {
                            c.fail(token, result.Status() == GattCommunicationStatus::AccessDenied ? E_ACCESSDENIED : E_FAIL); return;
                        }
                        auto& link = *c.links.at(token);
                        for (auto const& service : result.Services()) link.services.push_back(service);
                        link.ready = true;
                        auto e = c.event(S2W_CONNECTED, token); e.flags = link.session.MaxPduSize(); c.emit(e);
                    });
                });
            });
        } catch (hresult_error const& e) { fail(token, e.code()); }
    }
    void cancel(uint64_t token) {
        links.erase(token);
        emit(event(S2W_DISCONNECTED, token));
    }
    void discover(uint64_t token, size_t index = 0) {
        if (!links.count(token)) return;
        auto& link = *links.at(token);
        if (!link.ready || (index == 0 && link.discovering)) return;
        link.discovering = true;
        if (index == link.services.size()) { emit(event(S2W_SERVICES, token)); return; }
        after(link.services[index].GetCharacteristicsAsync(BluetoothCacheMode::Uncached), token,
              [token, index](Core& self, GattCharacteristicsResult result) {
            if (result.Status() != GattCommunicationStatus::Success) { self.fail(token, E_FAIL); return; }
            auto& l = *self.links.at(token);
            if (l.characteristics.size() + result.Characteristics().Size() > 128) { self.fail(token, E_OUTOFMEMORY); return; }
            for (auto const& value : result.Characteristics()) {
                auto e = self.event(S2W_CHARACTERISTIC, token);
                e.characteristic = static_cast<uint32_t>(l.characteristics.size());
                const auto id = to_string(to_hstring(value.Uuid()));
                // winrt::to_string(guid) includes braces; Swift expects UUID text.
                const auto plain = id.size() == 38 ? id.substr(1, 36) : id;
                if (plain.size() != 36) { self.fail(token, E_INVALIDARG); return; }
                std::memcpy(e.uuid, plain.data(), 36);
                auto properties = value.CharacteristicProperties();
                if ((properties & GattCharacteristicProperties::WriteWithoutResponse) != GattCharacteristicProperties::None) e.flags |= S2W_WRITE;
                if ((properties & GattCharacteristicProperties::Notify) != GattCharacteristicProperties::None) e.flags |= S2W_NOTIFY;
                if ((properties & GattCharacteristicProperties::Indicate) != GattCharacteristicProperties::None) e.flags |= S2W_INDICATE;
                Characteristic characteristic; characteristic.value = value;
                l.characteristics.push_back(std::move(characteristic)); self.emit(e);
            }
            self.discover(token, index + 1);
        });
    }
    void notify(uint64_t token, uint32_t index, bool enabled) {
        if (!links.count(token)) return;
        auto& link = *links.at(token);
        if (index >= link.characteristics.size()) { fail(token, E_INVALIDARG); return; }
        auto& ch = link.characteristics[index];
        if (enabled && !ch.registered) {
            auto weak = weak_from_this(); auto generation = epoch;
            ch.changed = ch.value.ValueChanged([weak, generation, token, index](auto const&, GattValueChangedEventArgs const& args) {
                if (auto owner = weak.lock()) {
                    try {
                        auto buffer = args.CharacteristicValue();
                        if (buffer.Length() > 512) {
                            owner->post([token](Core& c) { c.fail(token, E_INVALIDARG); }); return;
                        }
                        S2WEvent e{}; e.kind = S2W_VALUE; e.token = token; e.characteristic = index; e.length = buffer.Length();
                        DataReader::FromBuffer(buffer).ReadBytes(array_view<uint8_t>(e.bytes, e.bytes + e.length));
                        owner->post([generation, e](Core& c) {
                            if (c.epoch == generation && c.links.count(e.token)) c.emit(e);
                        });
                    } catch (...) { owner->post([token](Core& c) { c.fail(token, E_FAIL); }); }
                }
            });
            ch.registered = true;
        }
        const auto properties = ch.value.CharacteristicProperties();
        const auto setting = !enabled ? GattClientCharacteristicConfigurationDescriptorValue::None :
            (properties & GattCharacteristicProperties::Notify) != GattCharacteristicProperties::None ?
                GattClientCharacteristicConfigurationDescriptorValue::Notify : GattClientCharacteristicConfigurationDescriptorValue::Indicate;
        after(ch.value.WriteClientCharacteristicConfigurationDescriptorAsync(setting), token,
              [token, index, enabled](Core& self, GattCommunicationStatus status) {
            auto& ch = self.links.at(token)->characteristics.at(index);
            ch.notifying = enabled && status == GattCommunicationStatus::Success;
            if (!ch.notifying && ch.registered) { ch.value.ValueChanged(ch.changed); ch.registered = false; }
            auto e = self.event(S2W_NOTIFICATION, token); e.characteristic = index;
            e.flags = ch.notifying ? 1 : 0; e.status = status == GattCommunicationStatus::Success ? 0 : E_FAIL; self.emit(e);
        });
    }
    void write(uint64_t token, uint32_t index, std::array<uint8_t, 512> const& bytes, uint32_t length) {
        if (!links.count(token)) return;
        auto& link = *links.at(token);
        if (!link.ready || link.writing || index >= link.characteristics.size() ||
            link.session.MaxPduSize() < 3 || length > link.session.MaxPduSize() - 3u) { fail(token, E_INVALIDARG); return; }
        auto& ch = link.characteristics[index];
        if ((ch.value.CharacteristicProperties() & GattCharacteristicProperties::WriteWithoutResponse) == GattCharacteristicProperties::None) {
            fail(token, E_INVALIDARG); return;
        }
        DataWriter writer; writer.WriteBytes(array_view<uint8_t const>(bytes.data(), bytes.data() + length));
        link.writing = true;
        after(ch.value.WriteValueWithResultAsync(writer.DetachBuffer(), GattWriteOption::WriteWithoutResponse), token,
              [token](Core& self, GattWriteResult result) {
            if (result.Status() != GattCommunicationStatus::Success) { self.fail(token, E_FAIL); return; }
            self.links.at(token)->writing = false; self.emit(self.event(S2W_WRITABLE, token));
        });
    }
};
}
struct S2WRadio { std::shared_ptr<Core> core; };
extern "C" S2WRadio* s2w_create() {
    try {
        auto radio = std::make_unique<S2WRadio>(); radio->core = std::make_shared<Core>();
        auto* core = radio->core.get(); core->worker = std::thread([core] { core->run(); });
        return radio.release();
    } catch (...) { return nullptr; }
}
extern "C" void s2w_destroy(S2WRadio* radio) {
    if (!radio) return;
    { std::lock_guard<std::mutex> lock(radio->core->wakeMutex); radio->core->stopping.store(true); }
    radio->core->wake.notify_one();
    if (radio->core->worker.joinable()) radio->core->worker.join();
    delete radio;
}
extern "C" int32_t s2w_scan(S2WRadio* r, uint32_t enabled) {
    return r && enabled <= 1 && r->core->post([enabled](Core& c) { c.scan(enabled != 0); });
}
extern "C" int32_t s2w_connect(S2WRadio* r, uint64_t token, uint64_t address, uint32_t type) {
    return r && token && address && address <= 0xffffffffffffULL && type <= 1 &&
        r->core->post([=](Core& c) { c.connect(token, address, type); });
}
extern "C" int32_t s2w_cancel(S2WRadio* r, uint64_t token) {
    return r && token && r->core->post([token](Core& c) { c.cancel(token); });
}
extern "C" int32_t s2w_discover(S2WRadio* r, uint64_t token) {
    return r && token && r->core->post([token](Core& c) { c.discover(token); });
}
extern "C" int32_t s2w_notify(S2WRadio* r, uint64_t token, uint32_t index, uint32_t enabled) {
    return r && token && enabled <= 1 && r->core->post([=](Core& c) { c.notify(token, index, enabled != 0); });
}
extern "C" int32_t s2w_write(S2WRadio* r, uint64_t token, uint32_t index, const uint8_t* data, uint32_t length) {
    if (!r || !token || !data || !length || length > 512) return 0;
    std::array<uint8_t, 512> bytes{}; std::copy_n(data, length, bytes.data());
    return r->core->post([=](Core& c) { c.write(token, index, bytes, length); });
}
extern "C" int32_t s2w_next(S2WRadio* r, S2WEvent* event) {
    return r && event && r->core->events.pop(*event);
}
