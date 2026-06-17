# 本地 HTML 多标签浏览器（HtmlTabBrowser）

极简、Typora 风格的 Android（Kotlin）应用：用 SAF 选一个文件夹，浏览其中（含子文件夹）的
`.html` 文件，用带标签页的 WebView 打开。**只服务本地内容，不联网、无地址栏。**

## 功能

- **SAF 目录浏览**：首次选择一个文件夹（系统选择器），之后可在其中**进出子文件夹**分类查阅，
  列表区分文件夹与 `.html` 文件，文件显示修改时间/大小。
- **多标签**：同时打开多个文件，顶部标签栏可**切换 / 关闭单个标签**，「+」回到文件列表新建标签。
- **本地资源全可用**：JS / DOM Storage / 相对引用的 css/js/图片 / 同源 `fetch` 都正常工作
  （实现见下「为什么能用 SAF 还保留相对路径」）。
- 底部「后退/前进」**仅作用于当前标签**的 WebView 历史。
- **设置页**：主题（跟随系统/浅色/深色）、网页字体缩放、关闭标签前确认、阅读时常亮屏幕、
  清除缓存与 DOM 数据、关于。
- **Typora 风视觉**：大留白、细分隔线、扁平标签（选中底部 2dp 强调线）、浅/深双主题。
- **去掉的功能**：地址栏、搜索框、书签、历史记录、下载管理、分享、外部联网。

## 存储方案：SAF（无需任何权限）

要读取任意文件夹里的 HTML，本项目用 **Storage Access Framework**：用户用系统选择器挑一个目录，
应用通过 `takePersistableUriPermission` 拿到**可持久化的读权限**。因此：

- **不声明 `MANAGE_EXTERNAL_STORAGE`、不声明 `READ_*`**，更合规、对 Android 13/14/15 友好；
- **不声明 `INTERNET`**，从系统层面杜绝联网（另在 WebView 里再拦截 `http/https/ftp/ws` 双保险）。

> 取舍：相比「所有文件访问权限」，SAF 需要用户主动选一次文件夹，但换来零敏感权限。

### 为什么用 SAF 还能让相对路径 / fetch 正常工作

SAF 拿到的是 `content://` 文档 Uri，直接 `loadUrl` 会让 `<img src="x.png">` 这类**相对引用失效**。
解决办法：把选中的目录树**当成一个虚拟同源站点**——WebView 加载
`https://localhtml.invalid/<相对路径>`，在 `shouldInterceptRequest` 里按相对路径在目录树中
`findFile` 并返回对应文件的字节流（见 `LocalTreeServer.kt` 与 `MainActivity.serve()`）。
这样相对路径、同源 `fetch`、`localStorage` 全部照常工作，且是 https 安全上下文。

## 关键实现位置

| 关注点 | 文件 |
| --- | --- |
| 标签管理（增/切/关、destroy WebView） | `MainActivity.kt` 的 `openInNewTab/selectTab/closeTab` |
| 文件夹导航（进出子目录、面包屑） | `MainActivity.kt` 的 `pathDirs/refreshListing/goUpFolder` |
| 虚拟同源资源服务 | `LocalTreeServer.kt` + `MainActivity.serve()` |
| 状态栏遮挡修复（edge-to-edge insets） | `MainActivity.setupInsets()` |
| 设置项与持久化 | `SettingsFragment.kt` / `Prefs.kt` / `res/xml/preferences.xml` |
| 主题色（浅/深） | `res/values/colors.xml`、`res/values-night/colors.xml` |

## 兼容性

- `minSdk 24`（Android 7.0），`targetSdk / compileSdk 35`（Android 15）。
- 标签用**多个 WebView 实例**：切换只改 `visibility`，**不重载、不丢状态**；
  关闭标签 `removeView` + `destroy()`，`onDestroy` 销毁全部，避免内存泄漏。
- targetSdk 35 在 Android 15 强制 edge-to-edge，已用 `WindowInsets` 给顶/底栏加 padding，
  修复「标签栏与状态栏重叠、顶部点不到」的问题。

## 如何打包成 APK（debug）

### Android Studio
`Open` 选 `android-html-browser/` → 等 Gradle 同步 → `Build → Build APK(s)`，
产物在 `app/build/outputs/apk/debug/app-debug.apk`。

### 命令行（需 JDK 17、Android SDK，`ANDROID_HOME` 或 `local.properties` 指向 SDK）
```sh
cd android-html-browser
gradle wrapper --gradle-version 8.9   # 本仓库未提交 wrapper 二进制，首次生成一次
./gradlew assembleDebug
./gradlew installDebug                 # 安装到已连接设备
```

## 使用

1. 安装并打开 App，点「选择文件夹」，在系统选择器里挑一个存放 HTML 的目录并允许访问。
2. 列表里点文件夹进入分类、点 `.html` 在新标签打开；「+」可再开别的文件。
3. 右下角齿轮进入设置，可换主题、调字号、改文件夹等。
