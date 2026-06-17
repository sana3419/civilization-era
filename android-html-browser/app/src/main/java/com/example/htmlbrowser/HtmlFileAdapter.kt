package com.example.htmlbrowser

import android.text.format.DateUtils
import android.text.format.Formatter
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import androidx.documentfile.provider.DocumentFile

/**
 * 文件浏览适配器：同时展示子文件夹与 .html 文件。
 * 点击文件夹 → 进入；点击文件 → 打开新标签（由 Activity 决定）。
 */
class HtmlFileAdapter(
    private val onClick: (DocumentFile) -> Unit
) : RecyclerView.Adapter<HtmlFileAdapter.VH>() {

    private val items = mutableListOf<DocumentFile>()

    fun submit(newItems: List<DocumentFile>) {
        items.clear()
        items.addAll(newItems)
        notifyDataSetChanged()
    }

    class VH(view: View) : RecyclerView.ViewHolder(view) {
        val icon: ImageView = view.findViewById(R.id.fileIcon)
        val name: TextView = view.findViewById(R.id.fileName)
        val meta: TextView = view.findViewById(R.id.fileMeta)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val v = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_html_file, parent, false)
        return VH(v)
    }

    override fun onBindViewHolder(holder: VH, position: Int) {
        val doc = items[position]
        val ctx = holder.itemView.context
        holder.name.text = doc.name ?: "?"

        if (doc.isDirectory) {
            holder.icon.setImageResource(R.drawable.ic_folder)
            holder.meta.text = ctx.getString(R.string.folder_label)
        } else {
            holder.icon.setImageResource(R.drawable.ic_file)
            val size = Formatter.formatShortFileSize(ctx, doc.length())
            val time = DateUtils.getRelativeTimeSpanString(doc.lastModified())
            holder.meta.text = "$time · $size"
        }
        holder.itemView.setOnClickListener { onClick(doc) }
    }

    override fun getItemCount() = items.size
}
