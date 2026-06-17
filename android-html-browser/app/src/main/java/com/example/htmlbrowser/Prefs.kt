package com.example.htmlbrowser

import android.content.Context
import android.net.Uri
import androidx.appcompat.app.AppCompatDelegate
import androidx.preference.PreferenceManager

/** 集中读写设置（SharedPreferences），并统一主题应用逻辑。 */
object Prefs {
    const val KEY_THEME = "pref_theme"
    const val KEY_TREE_URI = "pref_tree_uri"
    const val KEY_TEXT_ZOOM = "pref_text_zoom"
    const val KEY_CONFIRM_CLOSE = "pref_confirm_close"
    const val KEY_KEEP_SCREEN_ON = "pref_keep_screen_on"

    private fun sp(c: Context) = PreferenceManager.getDefaultSharedPreferences(c)

    /** 用户用 SAF 选择的文件夹（目录树 Uri） */
    fun treeUri(c: Context): Uri? =
        sp(c).getString(KEY_TREE_URI, null)?.let(Uri::parse)

    fun setTreeUri(c: Context, uri: Uri?) {
        sp(c).edit().putString(KEY_TREE_URI, uri?.toString()).apply()
    }

    fun textZoom(c: Context): Int = sp(c).getInt(KEY_TEXT_ZOOM, 100)
    fun confirmClose(c: Context): Boolean = sp(c).getBoolean(KEY_CONFIRM_CLOSE, false)
    fun keepScreenOn(c: Context): Boolean = sp(c).getBoolean(KEY_KEEP_SCREEN_ON, false)

    /** 按设置应用浅色/深色/跟随系统 */
    fun applyTheme(c: Context) {
        val mode = when (sp(c).getString(KEY_THEME, "system")) {
            "light" -> AppCompatDelegate.MODE_NIGHT_NO
            "dark" -> AppCompatDelegate.MODE_NIGHT_YES
            else -> AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM
        }
        AppCompatDelegate.setDefaultNightMode(mode)
    }
}
