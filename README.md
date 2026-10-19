# Typemacs

Emacs 上的 Typst 工作台原型，复用 **Eglot + Tinymist + 网页预览**。Emacs 负责源码、会话和窗口，Tinymist 负责编译与源码映射，网页直接接收渲染更新。

当前实现：

- 实时预览未保存的源码修改，复用 Eglot 的文本同步。
- 按主文件与 document/slide 模式复用预览会话，多文件共享主文件。
- 源码到预览定位、预览到源码定位，以及可选的光标跟随。
- xwidget WebKit 内嵌侧窗；不支持 xwidget 时使用外部浏览器。
- 异步启动、停止、重启和失败处理；停止预览不关闭 Eglot。
- 支持 `typst-ts-mode`、`typst-mode`；附带无需语法库的最小源码模式。

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

预览中的反向定位手势由 Tinymist 网页前端提供。收到定位请求后，Typemacs 在源码窗口打开对应文件并高亮范围。

补全、诊断、跳转、重命名和格式化继续使用 Eglot 的标准功能。

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

模块边界与协议见 [docs/design.md](docs/design.md)。

当前限制：只支持本地文件；没有自动恢复预览会话、TRAMP/远程端口转发、模板库或独立导出菜单。语言服务重连后可重新运行 `typemacs-start`。部分位置转换和项目查询使用 Eglot 内部 API，已集中在适配层，升级 Eglot 时应运行回归测试。

GPL-3.0-or-later，见 [LICENSE](LICENSE)。
