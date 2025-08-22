import { ethers } from "hardhat"

async function main() {
  const contractAddr = process.env.CONTRACT_ADDRESS!
  const roundId = Number(process.env.ROUND_ID || 1)

  if (!contractAddr) {
    throw new Error("Missing CONTRACT_ADDRESS. Set env CONTRACT_ADDRESS=0x...")
  }

  const c = await ethers.getContractAt("VietlotCommitRevealV3", contractAddr)

  console.log("Re-requesting draw...")
  console.log("Contract address:", contractAddr)
  console.log("Round ID:", roundId)

  // Get the VRF fee
  const fee: bigint = await c.getRequestPrice()
  console.log("VRF fee:", fee.toString())

  try {
    await c.reRequestDrawIfStuck.staticCall(roundId, { value: fee })
  } catch (e: any) {
    console.error(
      "reRequestDrawIfStuck would revert:",
      e.shortMessage || e.reason || e.message,
    )
    console.error("Gợi ý:")
    console.error(" - Đảm bảo ví hiện tại là owner của contract")
    console.error(" - Round phải là current round")
    console.error(" - Round phải đã request draw nhưng chưa drawn")
    console.error(" - Phải đã qua REREQUEST_GRACE (1 hour) từ lần request cuối")
    process.exit(1)
  }

  const tx = await c.reRequestDrawIfStuck(roundId, { value: fee })
  console.log("Transaction hash:", tx.hash)

  const rcpt = await tx.wait()
  console.log("✅ Draw re-requested successfully!")
  console.log("Block number:", rcpt?.blockNumber)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
