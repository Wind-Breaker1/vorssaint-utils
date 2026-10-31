# 系统数据模块

独立接入个人工具，扫描注册表、阈值及分类保持与 macos-sysdata 对齐。

界面负责展示与选择，SystemDataService 在串行队列中编排扫描和清理；独立模型、命令执行器、文件身份检查及清理执行保存在 Services/SystemData 内。

不安装或注册系统数据辅助服务。同一批管理员项合并为一次 osascript 管理员授权，分别执行预定义操作并回传结果，不保存密码。清理后切换扫描状态刷新容量，失败项目保留原因。pnpm 使用 store prune，显示的整个存储大小不代表可全部回收。

运行 ./Tests/SystemDataIntegrationTests.sh 验证命令、文件保护、容量排除与模型分类。测试不执行真实系统清理。
