import { ethers } from "hardhat"

async function main() {
  const addr = process.env.CONTRACT_ADDRESS!
  const c = await ethers.getContractAt("VietlotCommitReveal", addr)
  const rid = Number((await c.currentRoundId()).toString())
  console.log("currentRoundId =", rid)
  try {
    const nums = await c.getWinningNumbers(rid)
    console.log(
      "drawn = TRUE, winning numbers:",
      nums.map((x: bigint) => Number(x)),
    )
  } catch {
    console.log("drawn = FALSE (NOT_DRAWN)")
  }
}
main().catch((e) => {
  console.error(e)
  process.exit(1)
})
