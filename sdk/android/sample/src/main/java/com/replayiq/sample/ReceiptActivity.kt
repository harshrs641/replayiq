package com.replayiq.sample

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.replayiq.android.ReplayIQ
import com.replayiq.android.compose.replayIQMask

class ReceiptActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ReplayIQ.screen("Receipt")
        setContent {
            MaterialTheme {
                Surface(Modifier.fillMaxSize().safeDrawingPadding()) {
                    Column(Modifier.verticalScroll(rememberScrollState()).padding(24.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.CheckCircle, contentDescription = "Paid", tint = Color(0xFF16A34A), modifier = Modifier.size(32.dp))
                            Text("Receipt", fontSize = 28.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 8.dp))
                        }
                        Spacer(Modifier.height(12.dp))
                        // A card: background colour, rounded shape and border come from its modifiers.
                        Column(
                            Modifier.fillMaxWidth()
                                .border(BorderStroke(1.dp, Color(0xFFC7D2FE)), RoundedCornerShape(12.dp))
                                .background(Color(0xFFEEF2FF), RoundedCornerShape(12.dp))
                                .semantics { }
                                .padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Text("Trail Runner 3 · $129.00", fontWeight = FontWeight.SemiBold)
                            Text("Shipping · $0.00", color = Color(0xFF6B7280))
                            // Masked with the Compose modifier.
                            Text("Card •••• 4242 · Auth 88A1Q", Modifier.replayIQMask())
                        }
                        Spacer(Modifier.height(16.dp))
                        var email by remember { mutableStateOf("") }
                        // Text fields never carry their value in recordings.
                        OutlinedTextField(email, { email = it }, label = { Text("Email for receipt") }, modifier = Modifier.fillMaxWidth())
                        var pin by remember { mutableStateOf("") }
                        OutlinedTextField(
                            pin, { pin = it }, label = { Text("Account PIN") },
                            visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth(),
                        )
                        Spacer(Modifier.height(16.dp))
                        Button(onClick = { ReplayIQ.track("receipt_emailed") }, modifier = Modifier.fillMaxWidth()) {
                            Text("Email receipt")
                        }
                        Spacer(Modifier.height(24.dp))
                        Text("Order history", fontSize = 20.sp, fontWeight = FontWeight.Bold)
                        for (i in 1..12) {
                            Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                                Text("Order #10${40 + i}")
                                Text("$${60 + i * 7}.00", color = Color(0xFF4F46E5))
                            }
                        }
                    }
                }
            }
        }
    }
}
