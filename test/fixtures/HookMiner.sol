// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library HookMiner {
    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    function mine(address deployer, bytes32 initCodeHash) internal pure returns (bytes32 salt) {
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            if (uint160(predict(deployer, salt, initCodeHash)) & 0x3fff == 0x00cc) return salt;
        }
        revert("salt search exhausted");
    }
}
