// SPDX-License-Identifier: BUSL-1.1

import { ethers } from "hardhat";
import { BigNumber } from "ethers";

async function main() {
  const decimal18 =  BigNumber.from(10).pow(18);

  const ONFTBridge = await ethers.getContractFactory("ONFTBridge");
  const bridge = await ONFTBridge.deploy("ONFT", "Test ONFT", "0xbfD2135BFfbb0B5378b56643c2Df8a87552Bfa23", "https://arweave.net/lSdEW6BafylhrF-1WZP3YQTMI8VPB0OBcM4SpInPnsk/"); // 1B tokens
  await bridge.deployed();

  console.log("Bridge contract:", bridge.address);


}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
