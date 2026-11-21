package com.replayiq.sample

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.Toast
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.replayiq.android.ReplayIQ

class ShopActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_shop)
        if (savedInstanceState == null) {
            supportFragmentManager.beginTransaction().replace(R.id.container, ProductsFragment()).commit()
        }
    }
}

class ProductsFragment : Fragment() {
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View =
        inflater.inflate(R.layout.fragment_products, container, false)

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        view.findViewById<RecyclerView>(R.id.products).apply {
            layoutManager = LinearLayoutManager(requireContext())
            adapter = ProductAdapter()
        }
        view.findViewById<Button>(R.id.add_to_cart).setOnClickListener {
            ReplayIQ.track("add_to_cart", mapOf("sku" to "TR3-42", "price" to 129.0))
            ReplayIQ.log("cart: added TR3-42")
            Toast.makeText(requireContext(), "Added to cart", Toast.LENGTH_SHORT).show()
        }
        view.findViewById<Button>(R.id.logout).setOnClickListener {
            ReplayIQ.reset() // ends this session (POST .../end) and starts a new one
            Toast.makeText(requireContext(), "Logged out", Toast.LENGTH_SHORT).show()
        }
        view.findViewById<Button>(R.id.checkout).setOnClickListener {
            startActivity(Intent(requireContext(), CheckoutActivity::class.java))
        }
    }
}
