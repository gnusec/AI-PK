# Linux TCP 超时问题分析报告

## 问题描述

在开发高性能端口扫描器时，我们遇到了Linux系统默认TCP连接超时的问题。当尝试连接到关闭的端口时，TCP协议栈会经历以下超时过程：

### Linux TCP 默认超时时间线：
1. **初始SYN超时**: 1秒
2. **第一次重试**: 3秒后
3. **第二次重试**: 9秒后
4. **第三次重试**: 21秒后
5. **第四次重试**: 45秒后
6. **总计超时时间**: **75秒**

这意味着如果扫描一个关闭的端口，程序会默认等待75秒才会超时，这使得扫描500个端口需要37500秒（超过10小时）！

## 当前实现的问题

我们当前的实现使用了 `std.net.tcpConnectToAddress()`，它没有提供超时参数：

```zig
const conn = net.tcpConnectToAddress(addr) catch {
    return false; // 但需要等待75秒才会到这里
};
```

## 解决方案：使用Socket层API设置超时

需要使用底层的socket API来设置发送和接收超时：

```zig
// 创建socket
const sock = os.socket(os.AF.INET, os.SOCK_STREAM, 0) catch return false;
defer os.close(sock);

// 设置超时选项
const timeout = os.timeval{
    .tv_sec = 3,  // 3秒超时
    .tv_usec = 0,
};

os.setsockopt(sock, os.IPPROTO.IP, os.SOL_SOCKET.SO_SNDTIMEO, std.mem.asBytes(&timeout)) catch return false;
os.setsockopt(sock, os.IPPROTO.IP, os.SOL_SOCKET.SO_RCVTIMEO, std.mem.asBytes(&timeout)) catch return false;

// 然后使用这个socket进行连接
```

## 性能目标

- **目标**: 500个端口扫描在10秒内完成
- **平均每个端口**: 20毫秒
- **并发连接数**: 需要 ~500个并发连接来达到目标
- **超时设置**: 3秒（避免75秒默认超时）

## 实现挑战

1. **Zig 0.15.1 API限制**: `std.net.tcpConnectToAddress` 不支持超时
2. **需要使用底层API**: 必须使用 `os.socket`, `os.setsockopt`, `os.connect`
3. **内存管理**: 大量并发连接需要有效的内存管理
4. **错误处理**: 需要正确处理各种网络错误

## 生产环境建议

1. **使用非阻塞socket**: 避免单个连接阻塞整个扫描过程
2. **连接池**: 复用socket连接
3. **异步I/O**: 使用epoll/kqueue进行事件驱动
4. **合理超时**: 根据网络环境调整超时时间

## 结论

Linux TCP的75秒默认超时是高性能端口扫描的主要障碍。必须使用底层socket API并设置适当的超时选项才能实现10秒内扫描500个端口的目标。

当前的实现验证了这个问题的存在，下一步需要实现基于socket的超时机制来解决性能瓶颈。