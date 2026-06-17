package com.example.htmlbrowser

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.view.LayoutInflater
import android.view.View
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.LinearLayoutManager
import com.example.htmlbrowser.databinding.ActivityMainBinding
import java.io.ByteArrayInputStream
import java.io.File

class MainActivity : AppCompatActivity() {

    companion object {
        // ===== 顶部常量：要扫描的本地 HTML 文件夹（按需修改）=====
        const val HTML_DIR = "/storage/emulated/0/MyHtml/"

        // 这些 scheme 视为“联网/外部”，一律拦截，只放行本地资源
        private val BLOCKED_SCHEMES = setOf("http", "https", "ftp", "ws", "wss")
    }

    private lateinit var binding: ActivityMainBinding
    private lateinit var fileAdapter: HtmlFileAdapter

    /** 一个标签：持有自己的 WebView 实例、chip 视图与标题视图 */
    private data class Tab(
        val webView: WebView,
        val chip: View,
        val titleView: TextView,
        val name: String
    )

    private val tabs = mutableListOf<Tab>()
    private var currentTab: Tab? = null

    // 申请 MANAGE_EXTERNAL_STORAGE 后从系统设置返回 → 重新检查并扫描
    private val manageStorageLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
            refreshFileListIfPermitted()
        }

    // Android 10 及以下的运行时读权限
    private val legacyPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) refreshFileListIfPermitted()
            else Toast.makeText(this, R.string.no_permission, Toast.LENGTH_LONG).show()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // 文件列表
        fileAdapter = HtmlFileAdapter { file -> openInNewTab(file) }
        binding.fileList.layoutManager = LinearLayoutManager(this)
        binding.fileList.adapter = fileAdapter

        // “+” 与底部“文件列表”都回到文件列表态
        binding.btnNewTab.setOnClickListener { showFileList() }
        binding.btnFileList.setOnClickListener { showFileList() }

        // 前进/后退只作用于当前标签的 WebView
        binding.btnBack.setOnClickListener {
            currentTab?.webView?.let { if (it.canGoBack()) it.goBack() }
        }
        binding.btnForward.setOnClickListener {
            currentTab?.webView?.let { if (it.canGoForward()) it.goForward() }
        }

        // 系统返回键：优先在当前标签内后退，其次退出
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                val wv = currentTab?.webView
                when {
                    // 文件列表态且已有标签 → 回到当前标签
                    binding.fileList.visibility == View.VISIBLE && tabs.isNotEmpty() ->
                        showCurrentTab()
                    // 标签内可后退
                    wv != null && wv.canGoBack() -> wv.goBack()
                    // 否则交还系统（退出应用）
                    else -> {
                        isEnabled = false
                        onBackPressedDispatcher.onBackPressed()
                    }
                }
            }
        })

        // 启动即检查权限并扫描
        ensureStoragePermission()
    }

    // ---------------------------------------------------------------------
    // 权限处理：MANAGE_EXTERNAL_STORAGE (API 30+) / READ_EXTERNAL_STORAGE (≤29)
    // ---------------------------------------------------------------------

    private fun ensureStoragePermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (Environment.isExternalStorageManager()) {
                refreshFileListIfPermitted()
            } else {
                showManageStorageDialog()
            }
        } else {
            val perm = android.Manifest.permission.READ_EXTERNAL_STORAGE
            if (ContextCompat.checkSelfPermission(this, perm)
                == android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                refreshFileListIfPermitted()
            } else {
                legacyPermissionLauncher.launch(perm)
            }
        }
    }

    /** 引导用户去系统设置开启“所有文件访问权限” */
    private fun showManageStorageDialog() {
        AlertDialog.Builder(this)
            .setTitle(R.string.permission_title)
            .setMessage(R.string.permission_message)
            .setCancelable(false)
            .setPositiveButton(R.string.grant_permission) { _, _ ->
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.parse("package:$packageName")
                }
                try {
                    manageStorageLauncher.launch(intent)
                } catch (e: Exception) {
                    // 个别厂商无此精确入口，退回到总列表页
                    manageStorageLauncher.launch(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                }
            }
            .show()
    }

    private fun hasStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(
                this, android.Manifest.permission.READ_EXTERNAL_STORAGE
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        }
    }

    // ---------------------------------------------------------------------
    // 扫描文件夹 → 文件列表
    // ---------------------------------------------------------------------

    private fun refreshFileListIfPermitted() {
        if (!hasStoragePermission()) return
        val dir = File(HTML_DIR)
        val htmlFiles = dir.listFiles { f ->
            f.isFile && (f.name.endsWith(".html", true) || f.name.endsWith(".htm", true))
        }?.sortedBy { it.name.lowercase() } ?: emptyList()

        fileAdapter.submit(htmlFiles)

        if (htmlFiles.isEmpty()) {
            binding.emptyHint.text = getString(R.string.empty_hint, HTML_DIR)
            binding.emptyHint.visibility = View.VISIBLE
        } else {
            binding.emptyHint.visibility = View.GONE
        }
        showFileList()
    }

    // ---------------------------------------------------------------------
    // 标签页管理
    // ---------------------------------------------------------------------

    /** 在新标签中打开一个本地 HTML 文件 */
    private fun openInNewTab(file: File) {
        val webView = createWebView()
        // chip 视图
        val chip = LayoutInflater.from(this)
            .inflate(R.layout.item_tab_chip, binding.tabContainer, false)
        val titleView = chip.findViewById<TextView>(R.id.tabTitle)
        titleView.text = file.name

        val tab = Tab(webView, chip, titleView, file.name)

        // 点击标题切换；点击 × 关闭
        titleView.setOnClickListener { selectTab(tab) }
        chip.findViewById<TextView>(R.id.tabClose).setOnClickListener { closeTab(tab) }

        // WebView 加入内容容器（默认隐藏，selectTab 再显示）
        binding.contentContainer.addView(
            webView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
        binding.tabContainer.addView(chip)
        tabs.add(tab)

        // 只加载一次本地文件
        webView.loadUrl(Uri.fromFile(file).toString())

        selectTab(tab)
    }

    /** 切换到某个标签：仅改可见性，不重新加载，避免丢状态 */
    private fun selectTab(tab: Tab) {
        currentTab = tab
        // 内容区：当前标签 WebView 可见，其余隐藏；文件列表隐藏
        for (t in tabs) {
            t.webView.visibility = if (t === tab) View.VISIBLE else View.GONE
        }
        binding.fileList.visibility = View.GONE
        binding.emptyHint.visibility = View.GONE
        updateChipStyles()
    }

    /** 关闭单个标签：从视图树移除并销毁 WebView，杜绝泄漏 */
    private fun closeTab(tab: Tab) {
        val index = tabs.indexOf(tab)
        if (index < 0) return

        tabs.removeAt(index)
        binding.tabContainer.removeView(tab.chip)
        binding.contentContainer.removeView(tab.webView)
        destroyWebView(tab.webView)

        if (currentTab === tab) {
            // 关掉的是当前标签：选相邻的；没有就回文件列表
            val next = tabs.getOrNull(index) ?: tabs.getOrNull(index - 1)
            if (next != null) selectTab(next) else {
                currentTab = null
                showFileList()
            }
        } else {
            updateChipStyles()
        }
    }

    /** 显示文件列表态（点击 + / 文件列表 / 无标签时） */
    private fun showFileList() {
        for (t in tabs) t.webView.visibility = View.GONE
        currentTab = null
        binding.fileList.visibility = View.VISIBLE
        binding.emptyHint.visibility =
            if (fileAdapter.itemCount == 0) View.VISIBLE else View.GONE
        updateChipStyles()
    }

    /** 从文件列表态返回到当前（最后一个）标签 */
    private fun showCurrentTab() {
        val tab = currentTab ?: tabs.lastOrNull() ?: return
        selectTab(tab)
    }

    /** 高亮当前标签 chip */
    private fun updateChipStyles() {
        for (t in tabs) {
            val active = t === currentTab
            t.chip.setBackgroundResource(R.drawable.tab_chip_bg)
            // mutate() 保证各 chip 的背景互不影响（否则共享 ConstantState 会串色）
            t.chip.background.mutate().setTint(
                ContextCompat.getColor(
                    this, if (active) R.color.tab_active else R.color.tab_inactive
                )
            )
        }
    }

    // ---------------------------------------------------------------------
    // WebView 创建与销毁
    // ---------------------------------------------------------------------

    @SuppressLint("SetJavaScriptEnabled")
    private fun createWebView(): WebView {
        val wv = WebView(this)
        wv.settings.apply {
            javaScriptEnabled = true            // 开启 JS
            domStorageEnabled = true            // 开启 DOM Storage (localStorage)
            allowFileAccess = true              // 允许访问 file://
            @Suppress("DEPRECATION")
            allowFileAccessFromFileURLs = true  // 本地页面可读其它本地文件
            @Suppress("DEPRECATION")
            allowUniversalAccessFromFileURLs = true // 本地页面 fetch/XHR 本地文件不受同源限制
            mediaPlaybackRequiresUserGesture = false
            loadWithOverviewMode = true
            useWideViewPort = true
            builtInZoomControls = true
            displayZoomControls = false
        }
        wv.webViewClient = object : WebViewClient() {
            // 拦截外部网址跳转：只允许本地 file://（及 data/blob 等本地 scheme）
            override fun shouldOverrideUrlLoading(
                view: WebView, request: WebResourceRequest
            ): Boolean {
                val scheme = request.url.scheme?.lowercase() ?: ""
                return scheme in BLOCKED_SCHEMES   // true=拦截，不加载外部网址
            }

            // 拦截子资源请求：阻断一切联网资源（外部 JS/CSS/图片/fetch）
            override fun shouldInterceptRequest(
                view: WebView, request: WebResourceRequest
            ): WebResourceResponse? {
                val scheme = request.url.scheme?.lowercase() ?: ""
                return if (scheme in BLOCKED_SCHEMES) {
                    WebResourceResponse(
                        "text/plain", "utf-8",
                        ByteArrayInputStream(ByteArray(0))
                    )
                } else null  // 本地资源放行
            }
        }
        return wv
    }

    /** 规范地销毁 WebView，防止内存泄漏 */
    private fun destroyWebView(wv: WebView) {
        wv.stopLoading()
        wv.loadUrl("about:blank")
        wv.clearHistory()
        (wv.parent as? FrameLayout)?.removeView(wv)
        wv.removeAllViews()
        wv.destroy()
    }

    // ---------------------------------------------------------------------
    // 生命周期转发
    // ---------------------------------------------------------------------

    override fun onPause() {
        super.onPause()
        currentTab?.webView?.onPause()
    }

    override fun onResume() {
        super.onResume()
        currentTab?.webView?.onResume()
    }

    override fun onDestroy() {
        // 退出时销毁所有 WebView
        for (t in tabs) destroyWebView(t.webView)
        tabs.clear()
        super.onDestroy()
    }
}
