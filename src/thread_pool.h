#pragma once

#include <algorithm>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace cive {

// 持久工作线程池。run() 带屏障；按线程序号固定切块，
// 块划分与 ceil(n/workers) 公式绑定 → 结果与线程调度无关（确定性前提）。
class ThreadPool {
    std::vector<std::thread> workers;
    std::mutex mu;
    std::condition_variable cv_job, cv_done;
    std::function<void(int, int)> job;
    int n_items = 0;
    uint64_t generation = 0;
    int remaining = 0;
    bool stopping = false;
    int count = 1;

    void worker_main(int p_idx) {
        uint64_t seen = 0;
        for (;;) {
            std::unique_lock<std::mutex> lk(mu);
            cv_job.wait(lk, [&] { return stopping || generation != seen; });
            if (stopping) {
                return;
            }
            seen = generation;
            const std::function<void(int, int)> fn = job;
            const int n = n_items;
            lk.unlock();

            const int chunk = (n + count - 1) / count;
            const int begin = p_idx * chunk;
            const int end = std::min(n, begin + chunk);
            if (begin < end) {
                fn(begin, end);
            }

            lk.lock();
            if (--remaining == 0) {
                cv_done.notify_one();
            }
        }
    }

public:
    explicit ThreadPool(int p_workers) : count(std::max(1, p_workers)) {
        workers.reserve(count);
        for (int i = 0; i < count; i++) {
            workers.emplace_back([this, i] { worker_main(i); });
        }
    }

    ~ThreadPool() {
        {
            std::lock_guard<std::mutex> lk(mu);
            stopping = true;
        }
        cv_job.notify_all();
        for (std::thread &w : workers) {
            w.join();
        }
    }

    int worker_count() const { return count; }

    void run(int p_n, std::function<void(int, int)> p_fn) {
        if (count <= 1 || p_n < 256) {
            p_fn(0, p_n);
            return;
        }
        {
            std::lock_guard<std::mutex> lk(mu);
            job = std::move(p_fn);
            n_items = p_n;
            remaining = count;
            generation++;
        }
        cv_job.notify_all();
        std::unique_lock<std::mutex> lk(mu);
        cv_done.wait(lk, [&] { return remaining == 0; });
    }
};

} // namespace cive
