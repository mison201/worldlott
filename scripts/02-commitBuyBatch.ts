import { ethers } from "hardhat"
import {
  sortAndCheck,
  parseNumbersFromEnv,
  abiEncodeRoundNumbersSaltUser,
  normalizeSaltToBytes32,
} from "./utils"

interface CommitData {
  numbers: number[]
  qty: bigint
  salt: `0x${string}`
  commitHash: string
}

async function main() {
  // --- Env & signer ---
  const [user] = await ethers.getSigners()
  const userAddr = await user.getAddress()
  const contractAddr = process.env.CONTRACT_ADDRESS!
  const k = Number(process.env.K || 6)
  const n = Number(process.env.N || 55)
  const gasBuffer: bigint = BigInt(
    process.env.GAS_BUFFER_WEI || "1000000000000000",
  ) // 0.001 STT

  if (!contractAddr) {
    throw new Error("Missing CONTRACT_ADDRESS. Set env CONTRACT_ADDRESS=0x...")
  }

  // --- Parse batch data from environment ---
  // Format: NUMBERS_BATCH="1,2,3,4,5,6:2;7,8,9,10,11,12:1;13,14,15,16,17,18:3"
  // Each entry is "numbers:quantity" separated by semicolons
  const batchData = process.env.NUMBERS_BATCH || ""
  if (!batchData) {
    throw new Error(
      'Missing NUMBERS_BATCH. Set env NUMBERS_BATCH="1,2,3,4,5,6:2;7,8,9,10,11,12:1"',
    )
  }

  const commits: CommitData[] = []
  const entries = batchData.split(";").filter((entry) => entry.trim())

  if (entries.length === 0) {
    throw new Error("No valid entries in NUMBERS_BATCH")
  }

  if (entries.length > 20) {
    throw new Error("Batch too large. Maximum 20 entries allowed.")
  }

  // --- Attach contract & read on-chain params ---
  const c = await ethers.getContractAt("VietlotCommitRevealV3", contractAddr)
  const roundId = Number((await c.currentRoundId()).toString())
  const onchainPrice: bigint = await c.ticketPrice()

  console.log("Processing batch commit...")
  console.log("Round ID:", roundId)
  console.log(
    "Ticket Price:",
    onchainPrice.toString(),
    `(~${ethers.formatEther(onchainPrice)} STT)`,
  )

  // --- Process each entry ---
  let totalQty = 0n
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i].trim()
    const [numbersStr, qtyStr] = entry.split(":")

    if (!numbersStr || !qtyStr) {
      throw new Error(
        `Invalid entry format at index ${i}: "${entry}". Expected "numbers:quantity"`,
      )
    }

    // Parse numbers
    const numbers = sortAndCheck(
      numbersStr
        .split(",")
        .map((s) => Number(s.trim()))
        .filter((v) => !Number.isNaN(v)),
      k,
      n,
    )

    // Parse quantity
    const qty = BigInt(qtyStr.trim())
    if (qty <= 0n || qty > 50n) {
      throw new Error(`Invalid quantity at index ${i}: ${qtyStr}. Must be 1-50`)
    }

    totalQty += qty

    // Generate salt for this commit
    const salt = normalizeSaltToBytes32()

    // Encode and hash
    const encoded = abiEncodeRoundNumbersSaltUser(
      roundId,
      numbers,
      salt,
      userAddr,
    )
    const commitHash = ethers.keccak256(encoded)

    commits.push({
      numbers,
      qty,
      salt,
      commitHash,
    })

    console.log(`Entry ${i + 1}:`, {
      numbers,
      qty: qty.toString(),
      salt,
      commitHash,
    })
  }

  if (totalQty > 100n) {
    throw new Error(`Total quantity ${totalQty} exceeds maximum of 100`)
  }

  const totalCost = onchainPrice * totalQty

  // --- Check balance ---
  const balance: bigint = await ethers.provider.getBalance(userAddr)
  if (balance < totalCost + gasBuffer) {
    console.error("❌ Insufficient balance for commitBuyBatch.")
    console.error("   Wallet      :", userAddr)
    console.error(
      "   Balance     :",
      balance.toString(),
      `(~${ethers.formatEther(balance)} STT)`,
    )
    console.error(
      "   Need (value):",
      totalCost.toString(),
      `(~${ethers.formatEther(totalCost)} STT)`,
    )
    console.error(
      "   Gas buffer  :",
      gasBuffer.toString(),
      `(~${ethers.formatEther(gasBuffer)} STT)`,
    )
    console.error(
      "   → Hãy nạp thêm STT testnet (faucet) hoặc giảm quantities.",
    )
    process.exit(1)
  }

  // --- Prepare batch data ---
  const commitHashes = commits.map((c) => c.commitHash)
  const quantities = commits.map((c) => c.qty)

  console.log("\nBatch Summary:")
  console.log("Total entries:", commits.length)
  console.log("Total quantity:", totalQty.toString())
  console.log(
    "Total cost:",
    totalCost.toString(),
    `(~${ethers.formatEther(totalCost)} STT)`,
  )

  // --- Dry-run to catch errors early ---
  try {
    await c.commitBuyBatch.staticCall(commitHashes, quantities, {
      value: totalCost,
    })
  } catch (e: any) {
    console.error(
      "commitBuyBatch would revert:",
      e.shortMessage || e.reason || e.message,
    )
    console.error("Gợi ý:")
    console.error(
      " - Nếu SALES_CLOSED: mở round mới hoặc commit trong thời gian sales.",
    )
    console.error(
      " - Nếu BAD_PAYMENT: kiểm tra lại giá vé on-chain & quantities.",
    )
    console.error(" - Nếu BATCH_TOO_LARGE: giảm số lượng entries (max 20).")
    console.error(" - Nếu TOTAL_QTY_EXCEEDED: giảm tổng quantity (max 100).")
    process.exit(1)
  }

  console.log("✅ Static call successful.")

  // --- Send transaction ---
  const tx = await c.commitBuyBatch(commitHashes, quantities, {
    value: totalCost,
  })
  console.log("Transaction hash:", tx.hash)

  const rcpt = await tx.wait()
  console.log("✅ Batch committed successfully!")
  console.log("Block number:", rcpt?.blockNumber)
  console.log("Gas used:", rcpt?.gasUsed?.toString())
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
