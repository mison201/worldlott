import { ethers } from "hardhat"
import { sortAndCheck, parseNumbersFromEnv, getSalt } from "./utils"

async function main() {
  const contractAddr = process.env.CONTRACT_ADDRESS!
  const roundId = Number(process.env.ROUND_ID || 1)
  const k = Number(process.env.K || 6)
  const n = Number(process.env.N || 55)
  const qty = BigInt(process.env.QTY || "1")
  const numbers = sortAndCheck(parseNumbersFromEnv(), k, n)
  const salt = getSalt()

  const c = await ethers.getContractAt("VietlotCommitReveal", contractAddr)
  const tx = await c.reveal(roundId, numbers, salt, qty)
  await tx.wait()
  console.log(
    "Revealed. roundId=",
    roundId,
    "numbers=",
    numbers,
    "qty=",
    qty.toString(),
  )
  console.log("salt used=", salt)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
