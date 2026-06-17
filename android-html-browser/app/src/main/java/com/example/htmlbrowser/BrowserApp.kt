package com.example.htmlbrowser

import android.app.Application

/** 进程启动时先应用主题设置，避免首帧闪烁。 */
class BrowserApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Prefs.applyTheme(this)
    }
}
