package com.example.htmlbrowser

import android.view.LayoutInflater
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import java.io.File

/**
 * 文件列表适配器：展示扫描到的 .html 文件名，点击回调打开新标签。
 */
class HtmlFileAdapter(
    private val onClick: (File) -> Unit
) : RecyclerView.Adapter<HtmlFileAdapter.VH>() {

    private val files = mutableListOf<File>()

    /** 刷新数据 */
    fun submit(newFiles: List<File>) {
        files.clear()
        files.addAll(newFiles)
        notifyDataSetChanged()
    }

    class VH(val text: TextView) : RecyclerView.ViewHolder(text)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val v = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_html_file, parent, false) as TextView
        return VH(v)
    }

    override fun onBindViewHolder(holder: VH, position: Int) {
        val file = files[position]
        holder.text.text = file.name
        holder.text.setOnClickListener { onClick(file) }
    }

    override fun getItemCount() = files.size
}
