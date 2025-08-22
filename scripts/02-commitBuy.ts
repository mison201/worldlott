import { ethers } from "hardhat"
import {
  sortAndCheck,
  parseNumbersFromEnv,
  abiEncodeRoundNumbersSaltUser,
  normalizeSaltToBytes32,
} from "./utils"

async function main() {
  // --- Env & signer ---
  const [user] = await ethers.getSigners()
  const userAddr = await user.getAddress()
  const contractAddr = process.env.CONTRACT_ADDRESS!
  const k = Number(process.env.K || 6)
  const n = Number(process.env.N || 55)
  const qty = BigInt(process.env.QTY || "1")
  const gasBuffer: bigint = BigInt(
    process.env.GAS_BUFFER_WEI || "1000000000000000",
  ) // 0.001 STT

  if (!contractAddr) {
    throw new Error("Missing CONTRACT_ADDRESS. Set env CONTRACT_ADDRESS=0x...")
  }

  // --- Parse & validate numbers ---
  const numbers = sortAndCheck(parseNumbersFromEnv(), k, n)

  // SALT chuẩn hoá về bytes32 (ổn định với mọi input)
  const salt = normalizeSaltToBytes32()

  // --- Attach contract & read on-chain params ---
  const c = await ethers.getContractAt("VietlotCommitRevealV3", contractAddr)

  // Luôn lấy roundId on-chain để chắc chắn đúng round hiện tại
  const roundId = Number((await c.currentRoundId()).toString())
  const onchainPrice: bigint = await c.ticketPrice()
  const value = onchainPrice * qty

  // --- Encode commit & hash ---
  const encoded = abiEncodeRoundNumbersSaltUser(
    roundId,
    numbers,
    salt,
    userAddr,
  )
  const commitHash = ethers.keccak256(encoded)

  // --- Check balance trước khi gửi giao dịch ---
  const balance: bigint = await ethers.provider.getBalance(userAddr)
  if (balance < value + gasBuffer) {
    console.error("❌ Insufficient balance for commitBuy.")
    console.error("   Wallet      :", userAddr)
    console.error(
      "   Balance     :",
      balance.toString(),
      `(~${ethers.formatEther(balance)} STT)`,
    )
    console.error(
      "   Need (value):",
      value.toString(),
      `(~${ethers.formatEther(value)} STT)`,
    )
    console.error(
      "   Gas buffer  :",
      gasBuffer.toString(),
      `(~${ethers.formatEther(gasBuffer)} STT)`,
    )
    console.error("   → Hãy nạp thêm STT testnet (faucet) hoặc giảm QTY.")
    process.exit(1)
  }

  // --- Dry-run để bắt revert reason sớm ---
  try {
    await c.commitBuy.staticCall(commitHash, qty, { value })
  } catch (e: any) {
    console.error(
      "commitBuy would revert:",
      e.shortMessage || e.reason || e.message,
    )
    console.error("Gợi ý:")
    console.error(
      " - Nếu SALES_CLOSED: mở round mới hoặc commit trong thời gian sales.",
    )
    console.error(" - Nếu BAD_PAYMENT: kiểm tra lại giá vé on-chain & QTY.")
    process.exit(1)
  }

  console.log("OK staticCall.")
  console.log("Signer      :", userAddr)
  console.log("roundId     :", roundId)
  console.log(
    "ticketPrice :",
    onchainPrice.toString(),
    `(~${ethers.formatEther(onchainPrice)} STT)`,
  )
  console.log("qty         :", qty.toString())
  console.log(
    "value       :",
    value.toString(),
    `(~${ethers.formatEther(value)} STT)`,
  )
  console.log("numbers     :", numbers)
  console.log("salt        :", salt)
  console.log("commitHash  :", commitHash)

  // --- Send tx ---
  const tx = await c.commitBuy(commitHash, qty, { value })
  console.log("tx hash     :", tx.hash)
  const rcpt = await tx.wait()
  console.log("✅ Committed. block:", rcpt?.blockNumber)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
