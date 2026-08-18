package com.phonerepair.phone_repair_shop

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var pendingSave: PendingSave? = null

    private class PendingSave(
        val bytes: ByteArray,
        val fileName: String,
        val result: MethodChannel.Result
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "savePdf" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val fileName = call.argument<String>("fileName") ?: "S1A.pdf"
                    if (bytes == null) {
                        result.error("bad_args", "bytes is null", null)
                    } else {
                        launchCreateDocument(bytes, fileName, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun launchCreateDocument(
        bytes: ByteArray,
        fileName: String,
        result: MethodChannel.Result
    ) {
        pendingSave = PendingSave(bytes, fileName, result)
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/pdf"
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        try {
            startActivityForResult(intent, REQ_CREATE_DOC)
        } catch (e: Exception) {
            pendingSave = null
            result.error("open_failed", "Không thể mở bảng chọn lưu: $e", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_CREATE_DOC) return
        val pending = pendingSave ?: return
        pendingSave = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pending.result.success(null)
            return
        }
        val uri: Uri = data.data!!
        try {
            contentResolver.openOutputStream(uri)?.use { out ->
                out.write(pending.bytes)
            } ?: run {
                pending.result.error("write_failed", "Không thể mở file để ghi.", null)
                return
            }
            val displayName = queryDisplayName(uri) ?: pending.fileName
            pending.result.success(displayName)
        } catch (e: Exception) {
            pending.result.error("write_failed", "Lưu file thất bại: $e", null)
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        private const val CHANNEL = "com.phonerepair.phone_repair_shop/save_file"
        private const val REQ_CREATE_DOC = 0x5A1
    }
}
