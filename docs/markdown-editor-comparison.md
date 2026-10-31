# WKWebView 笔记模块

笔记编辑已统一为 WKWebView + CodeMirror 6。Swift Markdown、Markdown Engine、NoteEditorKit 和原生富文本适配已移除。窗口内全部笔记 UI 使用本地网页，Swift 管理窗口、文件选择、笔记保存、附件和外部链接。

沿用单栏编辑 / 阅读切换，不使用分栏预览和格式工具栏。右键菜单提供格式、代码、提示框、表格、Mermaid、附件、模板导出。顶部仅保留标题和阅读/附件/更多操作，侧栏提供目录、链接、属性，标签在标题下方。

CodeMirror 编辑增强与 Markdown 渲染逻辑移植自 personal_station。Wiki Link 改为 `[[标题|UUID]]`，保留手工标题锚点的文本；跨笔记锚点定位尚待完善。代码支持行号、查找替换、撤销、快捷键、中文间距、列表续写和链接候选。阅读模式显示高亮、提示框、表格、代码、图片及 Mermaid。音视频目前作为附件链接打开，没有嵌入式播放器。Excalidraw 尚未接入。

所有网页资产打包在 Resources/NoteWeb，不依赖 CDN。笔记和附件继续存储在 Application Support/com.vorssaint.utils/Workspace。Web 页面不直接读写磁盘，通过受限消息桥接操作。远程图片加载受到 CSP 限制。导出复制相对附件；导入只读取正文。

关闭笔记窗口时保存最新已收到正文、停止加载并移除消息处理器。编辑器作为当前应用的独立模块存在，无需单独 App；未来可将 Web 模块和数据接口迁移出去。

## 构建和验证

普通 `./build.sh --dev` 使用已经提交的 Resources/NoteWeb 静态资源，无需安装 Node。

修改 Web 源码后，在 Web/NoteEditor 中运行 `pnpm install --frozen-lockfile`、`pnpm exec tsc --noEmit`、`pnpm test` 和 `pnpm build`，再构建应用。依赖安装时需要允许 esbuild 的安装脚本（或手动运行其 install.js）。Node 仅为开发依赖。

开发参数 `--preview-markdown-editor --probe-markdown-editor` 打开临时样例，验证编辑和阅读渲染。测试涵盖移植的表格、格式、提示框和列表逻辑；不代表全部 UI 和输入法组合已验证。

## 集成完善

正文变更立即交给 Swift 暂存，350 毫秒停顿后写入本地存储。切换笔记、关闭窗口和退出应用时提交已经收到的变更；Command S 立即保存。保存失败保留未保存状态，并在底栏显示错误。目录只解析标题，通过 React 延后更新，避免每次输入执行完整 HTML 渲染。

编辑模式通过 Wiki Link 候选面板插入链接；阅读模式可点击笔记链接，跨笔记链接支持标题定位。阅读模式支持本地音视频控件，PDF 和其他附件交给系统打开。窗口拆卸时销毁 CodeMirror 并移除消息桥接。

## React 页面迁移

笔记网页已统一为 React + TypeScript，移除旧手写 DOM 页面。MarkdownEditor、MarkdownPreview、OutlinePane、NotePropertiesPanel 及其右键菜单、弹层、日期选择器、图标和滚动容器复用 personal_station 源码。沿用原项目 Tailwind 设计变量、面板样式、Markdown 样式和背景，未引入原项目左侧全局功能导航；笔记窗口内保留可搜索、切换和新建笔记的列表。

保持明确的例外：不关联项目、不接入同步，不恢复顶部格式工具栏；按最新要求恢复编辑/实时预览双栏。笔记标题、模板/标签、目录/链接、下方属性面板沿用原项目排列；链接面板保留原项目上下两块独立滚动的布局，数据源改为当前 App 本地笔记。Wiki Link 使用已确认的 `[[标题|UUID#可选标题]]`。五种属性在桥接层转换到现有字符串存储，不引入第二套数据库。

编辑与阅读切换保留同一个 CodeMirror 实例，维持撤销历史、选择和编辑滚动位置；编辑态左右分栏显示源码和实时预览，按源码行同步滚动；阅读态仅显示预览。阅读模式关闭编辑器候选和右键菜单浮层。切换到另一篇笔记时重置编辑器状态，防止撤销跨笔记串入。

右键菜单的文本剪切、复制、粘贴经带回复的 WKWebView 消息桥接调用 NSPasteboard；普通浏览器开发时使用标准 Clipboard API。剪切只在复制成功且文档、选择未变化时删除文本；失败保留正文并提示。桥接仅接受本地主框架请求，窗口关闭时移除。

底部字数统计和状态栏均已移除；错误和操作提示在可关闭浮层中展示。

## 双类型笔记

新增入口并排提供 Markdown 和 Excalidraw 按钮。旧数据缺少 type 时按 Markdown 读取；Excalidraw 场景以 JSON 正文沿用同一份本地 notes.json 保存，图片随场景保存，不连接云服务。复用 Station 画布和主题，字体随 App 打包。Markdown 保留源码/预览双栏。笔记窗口最小内容尺寸为 1080 × 800。

按当前需求移除笔记导入入口与 Swift 导入消息处理；不提供导入导出。画板不显示 Markdown 模板。灵动岛新增菜单支持两种笔记类型。

笔记页已移除导入、导出及更多菜单，Swift 侧也移除对应文件面板和处理逻辑。

## 完整性补齐

笔记编辑窗口提供删除确认及恢复最近删除入口。删除项与正文一起持久化到 notes.json 的 deletedNotes 字段，旧数据无该字段时为空；删除或恢复写入失败回滚内存列表。删除最后一篇显示双类型新建和恢复入口。搜索覆盖标题、Markdown 正文和标签，不检索画板内部 JSON。链接面板优先显示目标当前名称，失效链接显示提示。画板拒绝非数组 elements 和无基本标识的元素。

验证：9 项 Web 测试；隔离临时目录中的 Swift 存储验证覆盖双类型、删除、重载后恢复及旧格式默认 Markdown。

## 编辑交互对照

以 personal_station 的 MarkdownEditor、MarkdownPreview、NoteMetadata、NoteEditor 和 useNoteDraft 为对照：

- 输入增强、快捷键、右键格式菜单、表格增行增列、Callout、中文间距、输入法保护直接沿用源实现。
- 复用 NoteMetadata，保留标签回车/失焦提交、去除开头 #、去重、标签移除提示和已存在标签时隐藏输入占位。
- 目录点击只平滑定位预览，不移动编辑光标；编辑滚动直接调用预览组件按源码行同步。
- 专注模式记忆到 localStorage；画布首次打开后保留实例，切换文档重置场景和历史，Markdown 模式隐藏并只读。画板不显示 Markdown 侧栏。
- 保存按钮和 Command S 提交未回车的标签。

保留的明确差异：不含项目、同步、导入导出、字数/状态底栏；新增入口双按钮；Wiki Link 使用约定格式；持久化由 Swift 本地存储负责，剪贴板由 AppKit 负责。Markdown 阅读切换保留编辑器撤销历史。未完成属性也保留本地草稿，避免关闭窗口丢失已输入内容；不照搬服务端提交限制。


## 附件与链接交互审查

附件支持文件选择、剪贴板粘贴和拖拽到光标位置；上传请求带当前编辑器与光标位置，切换笔记或关闭窗口后会取消待插入结果。Swift 校验图片、PDF、音频和视频类型并限制单文件 100 MB，使用 Application Support/Workspace/Attachments，正文只保存 Markdown 引用。预览将图片映射到受保护的 note-asset scheme，音视频附件转换为带控件的播放器，PDF 和其他附件交给系统打开。

Wiki Link 使用 `[[标题|UUID#标题]]`；补全支持上下键、Enter、Esc、候选弹层避让光标和滚动定位。阅读模式点击笔记链接可带标题跳转，页内锚点平滑滚动，HTTP、HTTPS、mailto 和本地附件交由 Swift 处理。反链和出链按 UUID 忽略大小写、自引用过滤、过滤不存在的目标，并在目标改名后显示当前名称。

界面细节：笔记窗口顶部留白收窄；内容区底部显示 Markdown 字数或 Excalidraw 类型；左侧列表顶部提供“回收站 · 恢复笔记”入口，恢复最近删除的本地笔记。
