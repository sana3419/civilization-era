package com.example.htmlbrowser

import android.os.Bundle
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import com.example.htmlbrowser.databinding.ActivitySettingsBinding

class SettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // 顶部工具栏下移到状态栏之下，内容底部避开导航栏
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            binding.toolbar.updatePadding(left = bars.left, top = bars.top, right = bars.right)
            binding.settingsContainer.updatePadding(bottom = bars.bottom)
            WindowInsetsCompat.CONSUMED
        }

        binding.toolbar.setNavigationOnClickListener { finish() }

        if (savedInstanceState == null) {
            supportFragmentManager.beginTransaction()
                .replace(R.id.settingsContainer, SettingsFragment())
                .commit()
        }
    }
}
