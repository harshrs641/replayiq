@file:JvmName("ReplayIQCompose")

package com.replayiq.android.compose

import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.semantics

/** Semantics key ReplayIQ reads when it masks Compose content. */
val ReplayIQMaskKey = SemanticsPropertyKey<Boolean>(
    name = "ReplayIQMask",
    mergePolicy = { parent, _ -> parent },
)

/**
 * Paint this composable over in recordings (`enabled = false` records it even when a default rule,
 * such as masking all text fields, would mask it).
 *
 * ```kotlin
 * Text(account.iban, modifier = Modifier.replayIQMask())
 * ```
 */
fun Modifier.replayIQMask(enabled: Boolean = true): Modifier = this.semantics { this[ReplayIQMaskKey] = enabled }
