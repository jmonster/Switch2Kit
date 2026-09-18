#pragma once
#include <cstddef>
#include <deque>
#include <mutex>
#include <utility>

namespace Switch2KitWinRT {
// Both events and commands have fixed admission limits. A caller must handle a
// false push; silently losing an input release or a cancellation is not allowed.
template<class T, size_t Capacity> class BoundedQueue {
    std::mutex mutex;
    std::deque<T> queue;
public:
    bool push(T value) {
        std::lock_guard<std::mutex> lock(mutex);
        if (queue.size() >= Capacity) return false;
        try { queue.push_back(std::move(value)); return true; }
        catch (...) { return false; }
    }
    bool pop(T& value) {
        std::lock_guard<std::mutex> lock(mutex);
        if (queue.empty()) return false;
        value = std::move(queue.front());
        queue.pop_front();
        return true;
    }
    bool empty() {
        std::lock_guard<std::mutex> lock(mutex);
        return queue.empty();
    }
    void clear() {
        std::lock_guard<std::mutex> lock(mutex);
        queue.clear();
    }
};
}
