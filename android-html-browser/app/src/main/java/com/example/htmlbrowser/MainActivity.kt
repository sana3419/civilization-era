package com.example.htmlbrowser

import android.annotation.SuppressLint
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.WindowManager
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.TextView
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.documentfile.provider.DocumentFile
import androidx.recyclerview.widget.LinearLayoutManager
import com.example.htmlbrowser.databinding.ActivityMainBinding
import java.io.ByteArrayInputStream

class MainActivity : AppCompatActivity() {

    companion object {
        // 虚拟同源：本地目录树以这个 https 站点的形式提供给 WebView
        private const val VHOST = "localhtml.invalid"
        private const val VBASE = "https://localhtml.invalid/"
    }

    private lateinit var binding: ActivityMainBinding
    private lateinit var fileAdapter: HtmlFileAdapter

    /** 一个标签：自己的 WebView 实例、chip、标题视图与相对路径 */
    private data class Tab(
        val webView: WebView,
        val chip: View,
        val titleView: TextView,
        val title: String
    )

    private val tabs = mutableListOf<Tab>()
    private var currentTab: Tab? = null

    // SAF 目录树服务（null = 尚未选择文件夹）
    private var server: LocalTreeServer? = null
    private var currentTreeUriString: String? = null

    // 文件夹导航栈：index 0 = 根目录，末尾 = 当前所在目录
    private val pathDirs = mutableListOf<DocumentFile>()

    // SAF 目录选择器
    private val pickTree =
        registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            if (uri != null) {
                // 持久化读权限，下次启动仍可访问
                contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
                Prefs.setTreeUri(this, uri)
                setTree(uri)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        setupInsets()

        // 文件浏览列表
        fileAdapter = HtmlFileAdapter { doc -> onFileItemClick(doc) }
        binding.fileList.layoutManager = LinearLayoutManager(this)
        binding.fileList.adapter = fileAdapter

        // 顶/底栏按钮
        binding.btnNewTab.setOnClickListener { showFileList() }
        binding.btnFiles.setOnClickListener { showFileList() }
        binding.btnSettings.setOnClickListener {
            startActivity(Intent(this, SettingsActivity::class.java))
        }
        binding.btnPickFolder.setOnClickListener { pickTree.launch(null) }
        binding.btnChangeFolder.setOnClickListener { pickTree.launch(null) }
        binding.btnUp.setOnClickListener { goUpFolder() }

        binding.btnBack.setOnClickListener {
            currentTab?.webView?.let { if (it.canGoBack()) it.goBack() }
        }
        binding.btnForward.setOnClickListener {
            currentTab?.webView?.let { if (it.canGoForward()) it.goForward() }
        }

        // 系统返回键：标签内后退 > 文件夹回上级 > 回当前标签 > 退出
        onBackPressedDispatcher.addCallback(this, object : androidx.activity.OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                val wv = currentTab?.webView
                when {
                    binding.fileListContainer.visibility == View.VISIBLE && pathDirs.size > 1 ->
                        goUpFolder()
                    binding.fileListContainer.visibility == View.VISIBLE && tabs.isNotEmpty() ->
                        showCurrentTab()
                    wv != null && wv.canGoBack() -> wv.goBack()
                    else -> {
                        isEnabled = false
                        onBackPressedDispatcher.onBackPressed()
                    }
                }
            }
        })
    }

    override fun onResume() {
        super.onResume()
        applyReadingPrefs()
        // 设置页可能改了文件夹 → 同步
        val uri = Prefs.treeUri(this)
        if (uri?.toString() != currentTreeUriString) {
            setTree(uri)
        }
        currentTab?.webView?.onResume()
    }

    override fun onPause() {
        super.onPause()
        currentTab?.webView?.onPause()
    }

    override fun onDestroy() {
        for (t in tabs) destroyWebView(t.webView)
        tabs.clear()
        super.onDestroy()
    }

    // ---------------------------------------------------------------------
    // 系统栏 inset（修复标签栏被状态栏遮挡、无法点击）
    // ---------------------------------------------------------------------

    private fun setupInsets() {
        val type = WindowInsetsCompat.Type.systemBars() or
                WindowInsetsCompat.Type.displayCutout()
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { _, insets ->
            val bars = insets.getInsets(type)
            // 顶栏下移到状态栏之下，底栏上移到导航栏之上
            binding.topBar.updatePadding(left = bars.left, top = bars.top, right = bars.right)
            binding.bottomBar.updatePadding(left = bars.left, bottom = bars.bottom, right = bars.right)
            WindowInsetsCompat.CONSUMED
        }
        // 浅色主题用深色状态栏图标，深色主题反之
        val night = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
        WindowCompat.getInsetsController(window, binding.root).apply {
            isAppearanceLightStatusBars = !night
            isAppearanceLightNavigationBars = !night
        }
    }

    // ---------------------------------------------------------------------
    // SAF 目录树
    // ---------------------------------------------------------------------

    /** 切换/初始化根目录 */
    private fun setTree(uri: Uri?) {
        closeAllTabs()
        currentTreeUriString = uri?.toString()
        pathDirs.clear()
        server = null

        if (uri != null) {
            val root = DocumentFile.fromTreeUri(this, uri)
            if (root != null && root.canRead()) {
                server = LocalTreeServer(this, root)
                pathDirs.add(root)
            }
        }
        showFileList()
    }

    private fun goUpFolder() {
        if (pathDirs.size > 1) {
            pathDirs.removeAt(pathDirs.size - 1)
            refreshListing()
        }
    }

    private fun onFileItemClick(doc: DocumentFile) {
        if (doc.isDirectory) {
            pathDirs.add(doc)
            refreshListing()
        } else {
            openInNewTab(doc)
        }
    }

    /** 当前目录相对根目录的路径前缀（如 "docs/api"） */
    private fun relPrefix(): String =
        pathDirs.drop(1).joinToString("/") { it.name ?: "" }

    /** 列出当前目录：子文件夹在前，.html 文件在后 */
    private fun refreshListing() {
        val current = pathDirs.lastOrNull()
        if (server == null || current == null) {
            binding.emptyText.text = getString(R.string.empty_no_folder)
            binding.emptyState.visibility = View.VISIBLE
            fileAdapter.submit(emptyList())
            return
        }

        val children = current.listFiles()
        val dirs = children.filter { it.isDirectory && it.canRead() }
            .sortedBy { (it.name ?: "").lowercase() }
        val files = children.filter {
            it.isFile && (it.name?.endsWith(".html", true) == true ||
                    it.name?.endsWith(".htm", true) == true)
        }.sortedBy { (it.name ?: "").lowercase() }

        val combined = dirs + files
        fileAdapter.submit(combined)

        // 路径面包屑
        val rootName = pathDirs.firstOrNull()?.name ?: ""
        val prefix = relPrefix()
        binding.pathText.text = if (prefix.isEmpty()) rootName else "$rootName / $prefix"
        binding.btnUp.alpha = if (pathDirs.size > 1) 1f else 0.3f
        binding.btnUp.isEnabled = pathDirs.size > 1

        if (combined.isEmpty()) {
            binding.emptyText.text = getString(R.string.empty_no_html)
            binding.emptyState.visibility = View.VISIBLE
        } else {
            binding.emptyState.visibility = View.GONE
        }
    }

    // ---------------------------------------------------------------------
    // 标签页
    // ---------------------------------------------------------------------

    private fun openInNewTab(doc: DocumentFile) {
        if (server == null) return
        val name = doc.name ?: return
        val prefix = relPrefix()
        val relPath = if (prefix.isEmpty()) name else "$prefix/$name"

        val webView = createWebView()
        val chip = LayoutInflater.from(this)
            .inflate(R.layout.item_tab_chip, binding.tabContainer, false)
        val titleView = chip.findViewById<TextView>(R.id.tabTitle)
        titleView.text = name

        val tab = Tab(webView, chip, titleView, name)
        titleView.setOnClickListener { selectTab(tab) }
        chip.setOnClickListener { selectTab(tab) }
        chip.findViewById<ImageButton>(R.id.tabClose).setOnClickListener { confirmCloseTab(tab) }

        binding.contentContainer.addView(
            webView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
        binding.tabContainer.addView(chip)
        tabs.add(tab)

        // 用虚拟同源地址加载，相对资源可正确解析
        val encoded = relPath.split('/').joinToString("/") { Uri.encode(it) }
        webView.loadUrl(VBASE + encoded)

        selectTab(tab)
    }

    private fun selectTab(tab: Tab) {
        currentTab = tab
        for (t in tabs) t.webView.visibility = if (t === tab) View.VISIBLE else View.GONE
        binding.fileListContainer.visibility = View.GONE
        binding.emptyState.visibility = View.GONE
        updateChipStyles()
        // 把选中标签滚动到可见
        binding.tabScroll.post { binding.tabScroll.requestChildRectangleOnScreen(tab.chip, android.graphics.Rect(0, 0, tab.chip.width, tab.chip.height), false) }
    }

    private fun confirmCloseTab(tab: Tab) {
        if (Prefs.confirmClose(this)) {
            AlertDialog.Builder(this)
                .setTitle(R.string.confirm_close_title)
                .setMessage(getString(R.string.confirm_close_msg, tab.title))
                .setPositiveButton(R.string.confirm) { _, _ -> closeTab(tab) }
                .setNegativeButton(R.string.cancel, null)
                .show()
        } else {
            closeTab(tab)
        }
    }

    private fun closeTab(tab: Tab) {
        val index = tabs.indexOf(tab)
        if (index < 0) return
        tabs.removeAt(index)
        binding.tabContainer.removeView(tab.chip)
        binding.contentContainer.removeView(tab.webView)
        destroyWebView(tab.webView)

        if (currentTab === tab) {
            val next = tabs.getOrNull(index) ?: tabs.getOrNull(index - 1)
            if (next != null) selectTab(next) else {
                currentTab = null
                showFileList()
            }
        } else {
            updateChipStyles()
        }
    }

    private fun closeAllTabs() {
        for (t in tabs) {
            binding.contentContainer.removeView(t.webView)
            destroyWebView(t.webView)
        }
        tabs.clear()
        binding.tabContainer.removeAllViews()
        currentTab = null
    }

    private fun showFileList() {
        for (t in tabs) t.webView.visibility = View.GONE
        currentTab = null
        binding.fileListContainer.visibility = View.VISIBLE
        refreshListing()
        updateChipStyles()
    }

    private fun showCurrentTab() {
        val tab = currentTab ?: tabs.lastOrNull() ?: return
        selectTab(tab)
    }

    private fun updateChipStyles() {
        for (t in tabs) {
            val active = t === currentTab
            t.chip.setBackgroundResource(
                if (active) R.drawable.tab_selected else R.drawable.tab_unselected
            )
            t.titleView.setTextColor(
                ContextCompat.getColor(
                    this, if (active) R.color.text_primary else R.color.text_secondary
                )
            )
        }
    }

    // ---------------------------------------------------------------------
    // WebView
    // ---------------------------------------------------------------------

    @SuppressLint("SetJavaScriptEnabled")
    private fun createWebView(): WebView {
        val wv = WebView(this)
        wv.setBackgroundColor(ContextCompat.getColor(this, R.color.bg))
        wv.settings.apply {
            javaScriptEnabled = true            // 开启 JS
            domStorageEnabled = true            // 开启 DOM Storage (localStorage)
            allowFileAccess = true
            mediaPlaybackRequiresUserGesture = false
            loadWithOverviewMode = true
            useWideViewPort = true
            builtInZoomControls = true
            displayZoomControls = false
            textZoom = Prefs.textZoom(this@MainActivity)
        }
        wv.webViewClient = object : WebViewClient() {
            // 只允许导航到本地虚拟同源，外部网址一律拦截
            override fun shouldOverrideUrlLoading(
                view: WebView, request: WebResourceRequest
            ): Boolean {
                val url = request.url
                val ok = (url.scheme == "https" || url.scheme == "http") && url.host == VHOST
                return !ok
            }

            // 资源请求：本地虚拟同源 → 从 SAF 目录树取流；联网请求 → 阻断
            override fun shouldInterceptRequest(
                view: WebView, request: WebResourceRequest
            ): WebResourceResponse? {
                val url = request.url
                val scheme = url.scheme?.lowercase() ?: ""
                return when {
                    (scheme == "http" || scheme == "https") && url.host == VHOST ->
                        serve(url) ?: notFound()
                    scheme == "http" || scheme == "https" ||
                            scheme == "ftp" || scheme == "ws" || scheme == "wss" ->
                        blocked()
                    else -> null   // file/data/blob 等本地 scheme 放行
                }
            }
        }
        return wv
    }

    /** 把虚拟同源请求映射到 SAF 目录树里的文件 */
    private fun serve(url: Uri): WebResourceResponse? {
        val s = server ?: return null
        val rel = url.path?.trimStart('/') ?: ""
        val doc = s.resolve(rel)
        if (doc == null || !doc.isFile) return null
        val stream = s.open(doc) ?: return null
        val mime = LocalTreeServer.guessMime(doc.name ?: rel)
        val enc = LocalTreeServer.encodingFor(mime)
        val resp = WebResourceResponse(mime, enc, stream)
        resp.responseHeaders = mapOf(
            "Cache-Control" to "no-cache",
            "Access-Control-Allow-Origin" to "*"
        )
        return resp
    }

    private fun blocked() = WebResourceResponse(
        "text/plain", "utf-8", 403, "Blocked",
        emptyMap(), ByteArrayInputStream(ByteArray(0))
    )

    private fun notFound() = WebResourceResponse(
        "text/plain", "utf-8", 404, "Not Found",
        emptyMap(), ByteArrayInputStream(ByteArray(0))
    )

    private fun destroyWebView(wv: WebView) {
        wv.stopLoading()
        wv.loadUrl("about:blank")
        wv.clearHistory()
        (wv.parent as? FrameLayout)?.removeView(wv)
        wv.removeAllViews()
        wv.destroy()
    }

    // ---------------------------------------------------------------------
    // 阅读相关设置
    // ---------------------------------------------------------------------

    private fun applyReadingPrefs() {
        val zoom = Prefs.textZoom(this)
        for (t in tabs) t.webView.settings.textZoom = zoom
        if (Prefs.keepScreenOn(this)) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
}
