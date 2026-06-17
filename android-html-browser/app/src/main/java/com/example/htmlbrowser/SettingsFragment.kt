package com.example.htmlbrowser

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.webkit.WebStorage
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.documentfile.provider.DocumentFile
import androidx.preference.ListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceFragmentCompat
import androidx.preference.SeekBarPreference

class SettingsFragment : PreferenceFragmentCompat() {

    // 设置页内也能直接选文件夹
    private val pickTree =
        registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            if (uri != null) {
                requireContext().contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
                Prefs.setTreeUri(requireContext(), uri)
                updateFolderSummary()
            }
        }

    override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
        setPreferencesFromResource(R.xml.preferences, rootKey)

        // 主题：切换后立即生效（setDefaultNightMode 会自动重建 Activity）
        findPreference<ListPreference>(Prefs.KEY_THEME)?.setOnPreferenceChangeListener { _, newValue ->
            val mode = when (newValue as String) {
                "light" -> androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_NO
                "dark" -> androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_YES
                else -> androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM
            }
            androidx.appcompat.app.AppCompatDelegate.setDefaultNightMode(mode)
            true
        }

        // 字体缩放滑块步进
        findPreference<SeekBarPreference>(Prefs.KEY_TEXT_ZOOM)?.apply {
            seekBarIncrement = 10
        }

        // 选择/更换文件夹
        findPreference<Preference>("pref_folder")?.apply {
            setOnPreferenceClickListener {
                pickTree.launch(null)
                true
            }
        }
        updateFolderSummary()

        // 清除缓存与 DOM 数据
        findPreference<Preference>("pref_clear")?.setOnPreferenceClickListener {
            WebStorage.getInstance().deleteAllData()
            runCatching { requireContext().cacheDir.deleteRecursively() }
            Toast.makeText(requireContext(), R.string.pref_clear_done, Toast.LENGTH_SHORT).show()
            true
        }

        // 关于：附带版本号
        findPreference<Preference>("pref_about")?.apply {
            val ver = runCatching {
                requireContext().packageManager
                    .getPackageInfo(requireContext().packageName, 0).versionName
            }.getOrNull() ?: "1.0"
            title = "${getString(R.string.pref_about_title)} · v$ver"
        }
    }

    /** 把当前文件夹名显示在「扫描文件夹」摘要里 */
    private fun updateFolderSummary() {
        val pref = findPreference<Preference>("pref_folder") ?: return
        val uri = Prefs.treeUri(requireContext())
        pref.summary = if (uri == null) {
            getString(R.string.pref_folder_unset)
        } else {
            folderDisplayName(uri)
        }
    }

    private fun folderDisplayName(uri: Uri): String {
        val name = DocumentFile.fromTreeUri(requireContext(), uri)?.name
        if (!name.isNullOrEmpty()) return name
        // 退化：从 tree uri 的 documentId 里取最后一段
        return Uri.decode(uri.lastPathSegment ?: uri.toString())
    }
}
