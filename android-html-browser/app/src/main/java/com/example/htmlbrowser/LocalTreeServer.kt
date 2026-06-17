package com.example.htmlbrowser

import android.content.Context
import androidx.documentfile.provider.DocumentFile
import java.io.InputStream
import java.net.URLConnection

/**
 * 把用户用 SAF 选中的目录树「当成一个本地站点根目录」来服务。
 *
 * WebView 以 https://[VHOST]/<相对路径> 的虚拟同源地址加载本地 HTML，
 * 页面里相对引用的 css/js/图片/fetch 都会落到本类的 [resolve]，
 * 我们按相对路径在目录树里逐级 findFile，再把对应文件的字节流返回。
 *
 * 这样既不需要任何存储权限（纯 SAF），又保留了相对路径与同源 fetch/localStorage。
 */
class LocalTreeServer(
    private val context: Context,
    val root: DocumentFile
) {
    // 相对路径 -> DocumentFile 的缓存（findFile 每次都要 query，缓存可显著加速）
    private val cache = HashMap<String, DocumentFile?>()

    /** 按相对路径（以 / 分隔，已解码）在目录树里定位文档 */
    fun resolve(relPath: String): DocumentFile? {
        val key = relPath.trim('/')
        cache[key]?.let { return it }
        if (cache.containsKey(key)) return null

        var doc: DocumentFile? = root
        if (key.isNotEmpty()) {
            for (seg in key.split('/')) {
                if (seg.isEmpty() || seg == ".") continue
                doc = doc?.findFile(seg)
                if (doc == null) break
            }
        }
        cache[key] = doc
        return doc
    }

    fun open(doc: DocumentFile): InputStream? =
        try {
            context.contentResolver.openInputStream(doc.uri)
        } catch (e: Exception) {
            null
        }

    companion object {
        /** 由扩展名推断 MIME（保证 css/js 能被正确应用） */
        fun guessMime(name: String): String {
            return when (name.substringAfterLast('.', "").lowercase()) {
                "html", "htm" -> "text/html"
                "css" -> "text/css"
                "js", "mjs" -> "application/javascript"
                "json" -> "application/json"
                "xml" -> "text/xml"
                "txt", "md" -> "text/plain"
                "csv" -> "text/csv"
                "svg" -> "image/svg+xml"
                "png" -> "image/png"
                "jpg", "jpeg" -> "image/jpeg"
                "gif" -> "image/gif"
                "webp" -> "image/webp"
                "bmp" -> "image/bmp"
                "ico" -> "image/x-icon"
                "woff" -> "font/woff"
                "woff2" -> "font/woff2"
                "ttf" -> "font/ttf"
                "otf" -> "font/otf"
                "mp3" -> "audio/mpeg"
                "wav" -> "audio/wav"
                "ogg" -> "audio/ogg"
                "mp4" -> "video/mp4"
                "webm" -> "video/webm"
                "pdf" -> "application/pdf"
                "wasm" -> "application/wasm"
                else -> URLConnection.guessContentTypeFromName(name) ?: "application/octet-stream"
            }
        }

        /** 文本类资源需要带 utf-8 编码 */
        fun encodingFor(mime: String): String? =
            if (mime.startsWith("text/") ||
                mime.endsWith("javascript") ||
                mime.endsWith("json") ||
                mime.endsWith("xml") ||
                mime == "image/svg+xml"
            ) "utf-8" else null
    }
}
