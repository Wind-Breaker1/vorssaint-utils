# 笔记模块

## 职责

- `Core/Notes/NoteModels.swift`：笔记、标签、属性模型。
- `Services/Notes/NotesFileRepository.swift`：独立文件读写、旧库迁移、附件拆分。
- `Services/Notes/NotesIndex.swift`：SQLite 元数据、FTS5 搜索和链接索引，使用绑定参数和事务。
- `Services/Notes/NotesDirectoryMigration.swift`：目录复制、流式校验、目标索引构建及失败清理。
- `Services/Notes/NotesIndexQueryService.swift`：串行复用只读 SQLite 连接，隔离搜索查询生命周期。
- `Services/Notes/NotesFlushRequest.swift`：窗口关闭时的保存结果协调对象。
- `Services/Notes/NotesStore.swift`：元数据列表、按需读取、保存及索引更新、后台搜索与重建。
- `UI/Notes/NotesWindowController.swift`：原生窗口创建、关闭、复用、尺寸约束。
- `UI/Notes/NotesEditorView.swift`：WKWebView、桥接、附件访问、保存防抖。
- `UI/Notes/NotesQuickSection.swift`：菜单入口。
- `UI/Notes/NotesStorageSettings.swift`：设置中的索引重建与目录入口。
- `Web/NoteEditor/src/features/notes`：编辑、预览、链接、属性和编解码。
- `Resources/NoteWeb`：build.mjs 生成的离线前端资源。

模块接入 AppFeature、FeatureRuntime、PanelLayout、Notch。卸载关闭窗口并保留数据。普通关闭刷新待保存内容，成功后销毁窗口与 WebView；最终保存失败则阻止关闭，保留编辑稿。Swift 负责文件与系统能力；React 只持有编辑和临时 UI 状态。专注模式不持久化，删除确认在网页内完成。

默认和最小内容区域为 1440×900，系统标题栏另计。NSWindow 在尺寸属性和缩放代理处执行约束。首帧前用匹配网页的暗色背景，避免 WebKit 白底。

## 文件是唯一权威数据源

根目录：`~/Library/Application Support/com.vorssaint.utils/Notes/`

```
Notes/
  笔记/<UUID>.md
  画板/<UUID>.excalidraw
  附件/<UUID 或内容散列>.<扩展名>
  index.sqlite             # SQLite 及运行时 WAL/SHM 辅助文件
  Migration/notes.json      # 旧整库 JSON 的迁移备份（或 workspace.json）
  .migration-complete
```

Markdown 使用 YAML front matter 边界，内部是 JSON 格式元数据（JSON 为 YAML 的兼容表示），正文保持 Markdown。画板保持场景 JSON，`vorssaint` 字段存笔记元数据。UUID 文件名保持改名时身份稳定，显示标题存在元数据中。单篇保存原子替换一个文件，不再重写整库。正文、属性、标签不依赖数据库恢复。

画板内嵌图片按 SHA-256 散列拆到附件目录，场景保存相对引用；打开画板时才还原给 Excalidraw 的数据 URL。索引扫描不加载图片二进制。暂不自动清理无引用附件，以免删除仍被其他笔记引用的资源。

旧 Workspace/notes.json（或 workspace.json）在迁移时先复制到 Migration，逐篇写入并验证后复制附件，最后写完成标记。重复运行不会覆盖已经存在的新笔记。旧目录原件保留，不继续作为运行时存储，也不自动删除。

## 索引与性能

SQLite 保存轻量元数据、摘要、链接关系、全文索引和文件修改签名。Store 和 Web 列表不加载全库正文，打开笔记才读完整文件。Web 收到元数据、摘要、出链 ID，入链不需要扫描所有正文。

启动按文件时间与大小签名增量校准索引，处理新增、删除和变更。保存只更新该篇文件及索引，并在内存中更新当前条目的摘要和排序，不重新解码整库元数据；文件成功但索引失败时报告错误，后续重建可从文件恢复。删除时若数据库更新失败则恢复原文件。

搜索通过独立的 `NotesIndexQueryService` 在后台串行队列复用只读 SQLite 连接查询 FTS5 trigram，三个及以上字符使用索引匹配，一个或两个字符在索引文本内扫描，支持中文和英文。结果带请求 ID，过期结果不覆盖新查询。搜索标题、正文（画板文字）和标签，不搜索图片二进制。

设置 → 笔记 → 重建笔记索引：先保存编辑会话，然后后台强制扫描全部文件，用事务清空并重建元数据、全文及链接索引。失败回滚保留原索引，不写笔记文件。按钮有忙碌状态和完成/错误提示；成功后刷新笔记会话。外部文件修改当前通过重新启动或手动重建生效，尚无目录实时监听。

## 验证

`bash Tests/NotesStorageIntegrationTests.sh` 使用临时目录验证迁移、独立文件、图片拆分、属性保留、中文/英文搜索、链接、重建、错误回滚，不使用用户目录。前端测试见 Web/NoteEditor/tests；应用构建使用 build.sh --dev。

### 用户配置存储目录

设置中的「更改目录」通过原生目录选择器选择空目录。目录访问书签保存在 UserDefaults，笔记内容不存入偏好设置。迁移先保存编辑中的文档、等待索引查询结束，再复制三个数据子目录及迁移备份，逐文件校验内容并在目标目录重建 SQLite 索引。成功后切换存储位置并删除原根目录；复制或校验失败时保留原目录。禁止选择非空目录及新旧互相包含的目录。若切换成功但原目录删除失败，界面显示清理错误。

## 代码审查与当前边界

已清理项目/领域候选信息、旧新建笔记下拉分支、无调用方的附件选择桥接、Markdown 重导出包装及重复 Mermaid 初始化。前端契约使用本地 contracts，没有 Tauri 调用或前端文件持久化。构建依赖图中的 contracts 是类型依赖，不属于未使用文件。

原生窗口/桥接、数据服务、纯模型保持分层；React 入口负责状态编排，编辑器、预览、画板、属性、链接各有组件。UI 入口仍可进一步拆分，但不需要增加通用框架。目录迁移在切换后、删除源目录之前继续持有旧目录访问授权。

已验证存储迁移、搜索与重建回滚、只读查询、目录迁移及失败清理，以及 11 项前端行为测试。尚未进行万篇笔记或超长文档的规模基准测试。当前限制：文件保存和目录迁移仍有主线程 I/O；全量重建期间可能与保存竞争 SQLite 写锁；笔记列表已使用固定行高和超量渲染的窗口化列表；Markdown 预览仍按全文渲染；独立文件的外部改动依赖启动或手动重建发现。后续优化应优先依据实测处理这些路径。
