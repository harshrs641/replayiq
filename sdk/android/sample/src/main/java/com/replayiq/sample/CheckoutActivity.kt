package com.replayiq.sample

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import com.replayiq.android.ReplayIQ
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException

class CheckoutActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_checkout)
        val status = findViewById<TextView>(R.id.status)

        // EditTexts are masked by default; this one is recorded on purpose.
        ReplayIQ.unmask(findViewById<EditText>(R.id.promo))

        findViewById<Button>(R.id.pay).setOnClickListener {
            status.text = "Processing…"
            ReplayIQ.track("checkout_submitted", mapOf("total" to 129.0))
            // Fails on purpose: the payments endpoint doesn't exist (404), recorded as a network event.
            val req = Request.Builder()
                .url(BuildConfig.REPLAYIQ_ENDPOINT + "/api/v1/payments?card_token=tok_secret")
                .post("{}".toRequestBody("application/json".toMediaType()))
                .build()
            SampleApp.http.newCall(req).enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) = show("Network error: ${e.message}")
                override fun onResponse(call: Call, response: Response) {
                    response.close()
                    if (!response.isSuccessful) {
                        ReplayIQ.log("payment failed with HTTP ${response.code}", "error")
                        show("Payment failed (HTTP ${response.code}). Try again.")
                    } else show("Paid!")
                }

                private fun show(msg: String) = runOnUiThread { status.text = msg }
            })
        }

        findViewById<Button>(R.id.receipt).setOnClickListener {
            startActivity(Intent(this, ReceiptActivity::class.java))
        }

        findViewById<Button>(R.id.crash).setOnClickListener {
            ReplayIQ.log("about to crash", "warn")
            throw IllegalStateException("Checkout crashed on purpose (sample app)")
        }
    }
}
