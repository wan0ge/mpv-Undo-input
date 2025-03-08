# mpv-Undo-input
在mpv中撤销或重置快捷键操作（撤销操作）

## 使用方法
将.lua文件放入scripts文件夹

使用Ctrl+Alt+z 撤销上一次操作

使用Ctrl+Alt+Backspace 重置上一次操作

如果快捷键不生效请在input.conf中添加
```
Ctrl+Alt+z script-message undo_last_action
ctrl+alt+BS script-message reset_last_action
```
## 注意事项
会读取input.conf文件获取默认值和监听快捷键保证可撤销操作的全面（但仍有无法撤回的）

默认忽略了窗口操作以及视频进度调节等操作

快捷键可以自定义，input.conf映射快捷键优先度大于lua内置快捷键

无配置文件，lua有简单的配置项可调节
![image](https://github.com/user-attachments/assets/2bd22258-83f2-418f-8daf-0f7f9770c8f0)
