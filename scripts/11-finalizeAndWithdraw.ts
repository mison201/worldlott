import { ethers } from "hardhat"

async function main() {
  const addr = process.env.CONTRACT_ADDRESS!
  const to =
    process.env.WITHDRAW_TO ||
    (await (await ethers.getSigners())[0].getAddress())
  const c = await ethers.getContractAt("VietlotCommitReveal", addr)
  const rid = Number((await c.currentRoundId()).toString())

  // finalize
  try {
    await c.finalizeRound.staticCall(rid)
    const tx1 = await c.finalizeRound(rid)
    await tx1.wait()
    console.log("✅ finalized round", rid)
  } catch (e: any) {
    console.log("finalizeRound skipped:", e.shortMessage || e.message)
  }

  // withdraw fee
  try {
    await c.withdrawOperatorFee.staticCall(rid, to)
    const tx2 = await c.withdrawOperatorFee(rid, to)
    await tx2.wait()
    console.log("✅ fee withdrawn to", to)
  } catch (e: any) {
    console.error("withdrawOperatorFee blocked:", e.shortMessage || e.message)
  }
}
main().catch((e) => {
  console.error(e)
  process.exit(1)
})
