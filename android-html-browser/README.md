# 本地 HTML 多标签浏览器（HtmlTabBrowser）

极简的 Android（Kotlin）应用：扫描手机上某个固定文件夹下的所有 `.html` 文件，
用带标签页的 WebView 打开它们。**只加载本地 `file://`，不联网、无地址栏。**

## 功能

- 启动后自动扫描固定文件夹（默认 `/storage/emulated/0/MyHtml/`），把 `.html`/`.htm`
  文件名列成可点击的列表。
- 多标签：可同时打开多个文件，顶部标签栏可**切换 / 关闭单个标签**，点 **「+」** 回到
  文件列表新建标签。
- WebView 已开启 `JavaScript`、`DOM Storage`、`allowFileAccess`、
  `allowFileAccessFromFileURLs`、`allowUniversalAccessFromFileURLs`，
  本地页面的 JS / CSS / 图片 / `fetch` 本地文件均可正常工作。
- 底部「‹ 后退 / 前进 ›」**仅作用于当前标签**的 WebView 历史。
- **去掉的功能**：地址栏、搜索框、书签、历史记录、下载管理、设置页、分享、外部联网。

## 关键实现位置

| 关注点 | 文件 |
| --- | --- |
| 扫描文件夹的常量路径 | `app/src/main/java/.../MainActivity.kt` 顶部 `HTML_DIR` |
| 标签管理（增/切/关、销毁 WebView） | `MainActivity.kt` 的 `openInNewTab / selectTab / closeTab` |
| WebView 安全开关与外链拦截 | `MainActivity.kt` 的 `createWebView()` |
| 存储权限处理 | `MainActivity.kt` 的 `ensureStoragePermission()` |
| 文件列表 | `HtmlFileAdapter.kt` |

## 存储权限取舍（重要）

要读取**任意文件夹**里的 `.html` 文件，有两条路：

- **`READ_MEDIA_IMAGES/VIDEO/AUDIO`**（Android 13+）：只能访问“媒体”文件。
  HTML 不是媒体类型，**扫不到**，不适用本场景。
- **`MANAGE_EXTERNAL_STORAGE`（所有文件访问）**：能读取整个外置存储下的任意文件。
  **本项目采用此方案。** 代价是需要用户在系统设置里手动开启（不能弹窗一键授权），
  且上架 Google Play 需额外声明用途。对“本地 HTML 阅读器”这种自用工具完全够用。

实现细节：
- Manifest 声明 `MANAGE_EXTERNAL_STORAGE`；Android 11+ 用
  `Environment.isExternalStorageManager()` 检查，未授权则跳转
  `Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION` 引导用户开启，
  返回应用后自动重新扫描。
- Android 10 及以下（API 24–29）退回传统 `READ_EXTERNAL_STORAGE` 运行时权限。
- **故意不声明 `INTERNET` 权限**，从系统层面杜绝联网，双保险（另在 WebView 里拦截
  `http/https/ftp/ws` 请求）。

## 兼容性

- `minSdk 24`（Android 7.0），`targetSdk / compileSdk 35`（Android 15，当前最新稳定版）。
- 标签用**多个 WebView 实例**管理：切换只改 `visibility`，**不重新加载、不丢状态**；
  关闭标签时 `removeView` + `destroy()`，`onDestroy` 销毁全部，避免内存泄漏。

## 如何打包成 APK（debug）

### 方式一：Android Studio（最省事）
1. `File → Open` 选择本目录 `android-html-browser/`。
2. 等待 Gradle 同步（会自动补齐 Gradle Wrapper）。
3. `Build → Build Bundle(s) / APK(s) → Build APK(s)`。
4. 产物在 `app/build/outputs/apk/debug/app-debug.apk`。

### 方式二：命令行
需本机已装 JDK 17 与 Android SDK，并设置 `ANDROID_HOME`（或在 `local.properties`
写 `sdk.dir=/path/to/Android/sdk`）。

```sh
cd android-html-browser
# 若没有 gradlew（本仓库未提交 wrapper 二进制），先用本机 gradle 生成一次：
gradle wrapper --gradle-version 8.9
# 然后打 debug 包：
./gradlew assembleDebug
# 安装到已连接的设备：
./gradlew installDebug
```

APK 路径：`app/build/outputs/apk/debug/app-debug.apk`。

## 使用

1. 在手机上新建文件夹 `/storage/emulated/0/MyHtml/`（即“内部存储/MyHtml”），
   把你的 `.html` 及其依赖的 css/js/图片放进去。
2. 安装并打开 App，按提示授予“所有文件访问权限”。
3. 文件列表里点文件 → 在新标签打开；点「+」可再开别的文件。

> 想换扫描目录：改 `MainActivity.kt` 顶部的 `HTML_DIR` 常量即可。
