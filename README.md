# Typemacs

Emacs 上的 Typst 工作台原型，复用 **Eglot + Tinymist + 网页预览**。Emacs 负责源码、会话和窗口，Tinymist 负责编译与源码映射，网页直接接收渲染更新。

当前实现：

- 实时预览未保存的源码修改，复用 Eglot 的文本同步。
- 按主文件与 document/slide 模式复用预览会话，多文件共享主文件。
- 源码到预览定位、预览到源码定位，以及可选的光标跟随。
- xwidget WebKit 内嵌侧窗；不支持 xwidget 时使用外部浏览器。
- 异步启动、停止、重启和失败处理；停止预览不关闭 Eglot。
- 支持 `typst-ts-mode`、`typst-mode`；附带无需语法库的最小源码模式。
- Org 风格的 Typst 表格导航、对齐和行列编辑，无需启动语言服务。

## 开始使用

需要 Emacs 29.1 或更新版本，以及 PATH 中支持预览扩展命令的 `tinymist`。可通过 `tinymist --version` 检查二进制。Emacs 的 `exec-path` 也必须能找到它。

将下面配置加入 Emacs，路径换成此仓库的实际位置：

```elisp
(add-to-list 'load-path "/path/to/typemacs")
(require 'typemacs)
(typemacs-setup)
```

打开 [examples/main.typ](examples/main.typ)，运行 `M-x typemacs-start`。第一次会连接 Tinymist，随后打开预览。已有 Eglot 连接会被复用。主文件首次启动前需要在磁盘上存在，之后的编辑无需保存即可预览。

已有 `.typ` major mode 配置会优先于自带的 `typemacs-source-mode`。这个 fallback 只提供基础高亮与注释；完整语法高亮和缩进建议使用 `typst-ts-mode`。

## 命令

在源码 buffer 中启用的 `typemacs-mode` 提供以下快捷键：

| 按键 | 命令 | 用途 |
|---|---|---|
| `C-c C-t p` | `typemacs-start` | 启动或打开预览；加前缀参数选择主文件 |
| `C-c C-t q` | `typemacs-stop` | 停止当前预览任务 |
| `C-c C-t r` | `typemacs-restart` | 保持主文件和模式，重启预览 |
| `C-c C-t o` | `typemacs-open-preview` | 再次打开预览 |
| `C-c C-t j` | `typemacs-forward-search` | 定位当前源码对应的预览位置 |
| `C-c C-t f` | `typemacs-toggle-follow` | 开关当前 buffer 的光标跟随 |
| `C-c C-t m` | `typemacs-set-main-file` | 选择主文件并启动或加入其预览 |
| `C-c C-t s` | `typemacs-status` | 查看状态、主文件与预览地址 |
| `C-c C-t w` | `typemacs-switch-window` | 切换源码与内嵌预览窗口 |
| `C-c C-t t` / `C-c \|` | `typemacs-table-insert` | 按列数、行数插入表格 |
| `C-c C-t a` | `typemacs-table-align` | 对齐光标所在的表格 |

预览中的反向定位手势由 Tinymist 网页前端提供。收到定位请求后，Typemacs 在源码窗口打开对应文件并高亮范围。

补全、诊断、跳转、重命名和格式化继续使用 Eglot 的标准功能。

## 表格编辑

启用 `typemacs-mode` 后，可像 Org table 一样直接编辑 `#table(...)` 的源码。运行 `C-c |`，输入列数和行数，光标会停在第一个 `[]` 内；也可以编辑已有表格：

```typst
#table(
  columns: (auto, 1fr),
  table.header(
    [Name],   [Value],
  ),
  [Alpha],  [10],
  [Beta],   [20],
)
```

光标在单元格内时启用以下按键，表格外以及 `columns:` 等参数内保留 major mode 的原有绑定：

| 按键 | 操作 |
|---|---|
| `TAB` / `S-TAB` | 对齐并进入下一格 / 上一格；最后一格后自动添加一行 |
| `RET` | 对齐并进入下一行的同一列；末行自动添加一行 |
| `C-c C-c` | 对齐当前表格，保留格内光标位置 |
| `M-↑` / `M-↓` | 上移 / 下移当前行 |
| `M-←` / `M-→` | 左移 / 右移当前列 |
| `M-S-↓` / `M-S-↑` | 在当前行前插入空行 / 删除当前行 |
| `M-S-→` / `M-S-←` | 在当前列前插入空列 / 删除当前列 |

对应命令均以 `typemacs-table-` 开头，可通过 `M-x` 调用。行移动限制在当前表体、`table.header` 或 `table.footer` 内；列操作同步更新所有区段和 `columns`，新增列的宽度为 `auto`。每次编辑可一步撤销，末行缺少的单元格会补为 `[]`，每个区段至少保留一行，表格至少保留一列。

支持正整数列数和字面量列宽元组，如 `columns: 3`、`columns: (auto, 1fr, 2fr)`；省略时按默认的一列处理。单元格可以包含嵌套内容、函数调用、字符串、数学公式、注释或多行文字。对齐保留单元格内容，多行单元格逐格排版。

表格编辑不求值 Typst 代码。动态列数、展开参数（`..cells`）、直接使用 `table.cell` 的单元格以及 `table.hline` / `table.vline` 暂不支持，显式调用命令时会提示原因。使用 `set` / `show` 规则改变默认列数的表格应显式填写 `columns`。

## 多文件文档

打开 `examples/chapters/intro.typ` 后，运行 `typemacs-set-main-file` 并选择 `examples/main.typ`。这会加入已有的主文件预览，而不是把章节单独编译。

也可以在配置中设置 buffer-local 变量：

```elisp
;; 相对路径以当前源码文件所在目录为基准。
(setq-local typemacs-main-file "../main.typ")
```

持久配置可使用 Emacs 的文件局部变量或目录局部变量。为整个项目配置时，绝对路径能避免不同子目录的相对路径歧义。主文件必须位于 Eglot 项目根目录内。

同一个 Eglot 连接仍然同步其管理的全部源码 buffer。加入预览会话用于确定定位和生命周期归属，不会额外发送一份源码。

## 浏览器与选项

```elisp
;; 默认：图形界面下有 xwidget 则内嵌，否则使用系统浏览器。
(setq typemacs-browser 'auto)

;; 也可以显式指定；xwidget 需要 Emacs 构建时启用 WebKit 支持。
(setq typemacs-browser 'xwidget) ; 或 'external

;; 自定义打开方式，函数接收 URL。
(setq typemacs-browser (lambda (url) (browse-url-firefox url)))

(setq typemacs-tinymist-command '("/path/to/tinymist" "lsp"))
(setq typemacs-invert-colors 'auto) ; auto / never / always
(setq typemacs-follow-delay 0.15)

;; 以下设置针对当前源码 buffer；改变后重新启动预览。
(setq-local typemacs-preview-mode 'slide) ; 或 'document
```

EWW 不具备运行这个动态预览所需的 JavaScript/WebSocket 能力。外部浏览器拥有与内嵌页面相同的实时更新和定位协议；`typemacs-switch-window` 仅适用于内嵌预览。

预览服务使用 `127.0.0.1` 和随机端口，不启动额外的 Node/Python 桥接服务。杀死内嵌预览 buffer 会停止任务；隐藏窗口会保留会话。外部浏览器的标签页关闭由 Tinymist 自身检测，Emacs 端也可显式运行 `typemacs-stop`。

## 开发与验证

```sh
make check        # 严格字节编译 + ERT 回归测试
make integration  # 使用本机 Tinymist，启动本地 HTTP 预览
```

集成测试在临时目录创建双文件文档，检查网页响应、章节共用会话、未保存修改触发诊断及恢复、定位命令，以及停止预览后语言服务继续可用。它不启动浏览器。图形界面的 WebKit 渲染、鼠标手势和窗口缩放仍需要手动验收。

表格回归测试覆盖导航、行列操作、列宽、表头表尾、Unicode、多行内容、注释、嵌套表格、按键回退与撤销。本机存在 `typst` 时，还会编译行列编辑各阶段的源码；未安装时仅跳过该项编译验证。

模块边界与协议见 [docs/design.md](docs/design.md)。

当前限制：只支持本地文件；没有自动恢复预览会话、TRAMP/远程端口转发、模板库或独立导出菜单。语言服务重连后可重新运行 `typemacs-start`。部分位置转换和项目查询使用 Eglot 内部 API，已集中在适配层，升级 Eglot 时应运行回归测试。

GPL-3.0-or-later，见 [LICENSE](LICENSE)。
