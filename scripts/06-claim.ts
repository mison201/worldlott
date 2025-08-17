import { ethers } from "hardhat"
import { parseNumbersFromEnv, sortAndCheck } from "./utils"

async function main() {
  const contractAddr = process.env.CONTRACT_ADDRESS!
  const roundId = Number(process.env.ROUND_ID || 1)
  const k = Number(process.env.K || 6)
  const n = Number(process.env.N || 55)
  const qty = BigInt(process.env.QTY || "1")
  const numbers = sortAndCheck(parseNumbersFromEnv(), k, n)

  const c = await ethers.getContractAt("VietlotCommitReveal", contractAddr)
  const tx = await c.claim(roundId, numbers, qty)
  const rcpt = await tx.wait()
  console.log("Claimed. TX:", rcpt?.hash)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
