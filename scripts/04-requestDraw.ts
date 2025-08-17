import { ethers } from "hardhat"
async function main() {
  const addr = process.env.CONTRACT_ADDRESS!
  const c = await ethers.getContractAt("VietlotCommitReveal", addr)
  const fee: bigint = await c.getRequestPrice()
  console.log("VRF fee:", fee.toString())
  try {
    await c.requestDraw.staticCall({ value: fee }) // nếu chưa qua revealEnd -> REVEAL_NOT_ENDED
  } catch (e: any) {
    console.error(
      "requestDraw would revert:",
      e.shortMessage || e.reason || e.message,
    )
    process.exit(1)
  }
  const tx = await c.requestDraw({ value: fee })
  console.log("requestDraw tx:", tx.hash)
  await tx.wait()
  console.log("Requested. Chờ VRF fulfill rồi mới mở round tiếp.")
}
main().catch((e) => {
  console.error(e)
  process.exit(1)
})
