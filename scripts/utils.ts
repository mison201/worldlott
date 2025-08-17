import { ethers } from "hardhat"
import crypto from "crypto"

export function parseNumbersFromEnv(): number[] {
  const raw = process.env.NUMBERS || ""
  const nums = raw
    .split(",")
    .map((s) => Number(s.trim()))
    .filter((v) => !Number.isNaN(v))
  return nums
}

export function sortAndCheck(nums: number[], k: number, n: number): number[] {
  if (nums.length !== k) throw new Error(`Need exactly ${k} numbers`)
  const sorted = [...nums].sort((a, b) => a - b)
  for (let i = 0; i < sorted.length; i++) {
    if (sorted[i] < 1 || sorted[i] > n) throw new Error("Out of range")
    if (i > 0 && sorted[i] === sorted[i - 1]) throw new Error("Duplicate")
  }
  return sorted
}

/**
 * Trả về bytes32 hợp lệ từ biến môi trường SALT:
 * - Nếu SALT rỗng: sinh ngẫu nhiên 32 bytes.
 * - Nếu SALT là hex: zero-pad đến 32 bytes.
 * - Nếu SALT là chuỗi thường: keccak256(utf8).
 */
export function normalizeSaltToBytes32(): `0x${string}` {
  const input = process.env.SALT || ""
  if (!input)
    return ("0x" + crypto.randomBytes(32).toString("hex")) as `0x${string}`
  if (ethers.isHexString(input)) {
    return ethers.hexlify(
      ethers.zeroPadValue(input as `0x${string}`, 32),
    ) as `0x${string}`
  }
  return ethers.id(input) as `0x${string}`
}

/** keccak256(abi.encode(roundId, numbers[], salt, user)) */
export function abiEncodeRoundNumbersSaltUser(
  roundId: number,
  numbers: number[],
  salt: `0x${string}`,
  user: string,
): string {
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    ["uint256", "uint8[]", "bytes32", "address"],
    [roundId, numbers, salt, user],
  )
}
