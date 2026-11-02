// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MetadataUtils
 * @notice Utility functions for metadata handling
 */
library MetadataUtils {
    /**
     * @notice Validate metadata URI format
     * @param uri Metadata URI to validate
     * @return True if URI is valid
     */
    function isValidURI(string memory uri) internal pure returns (bool) {
        bytes memory uriBytes = bytes(uri);
        if (uriBytes.length == 0) return false;

        // Check for common URI schemes
        if (startsWith(uri, "http://") ||
            startsWith(uri, "https://") ||
            startsWith(uri, "ipfs://") ||
            startsWith(uri, "ar://") ||
            startsWith(uri, "data:")) {
            return true;
        }

        return false;
    }

    /**
     * @notice Check if string starts with prefix
     * @param str String to check
     * @param prefix Prefix to check for
     * @return True if string starts with prefix
     */
    function startsWith(
        string memory str,
        string memory prefix
    ) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory prefixBytes = bytes(prefix);

        if (prefixBytes.length > strBytes.length) {
            return false;
        }

        for (uint256 i = 0; i < prefixBytes.length; i++) {
            if (strBytes[i] != prefixBytes[i]) {
                return false;
            }
        }

        return true;
    }

    /**
     * @notice Validate name for URL safety (case-insensitive)
     * @param name Name to validate
     * @return True if name is valid
     */
    function isValidName(string memory name) internal pure returns (bool) {
        bytes memory nameBytes = bytes(name);
        
        if (nameBytes.length == 0 || nameBytes.length > 64) {
            return false;
        }

        for (uint256 i = 0; i < nameBytes.length; i++) {
            bytes1 char = nameBytes[i];
            
            // Allow alphanumeric and hyphens/underscores
            if (!((char >= 0x30 && char <= 0x39) || // 0-9
                  (char >= 0x41 && char <= 0x5A) || // A-Z
                  (char >= 0x61 && char <= 0x7A) || // a-z
                  char == 0x2D || // -
                  char == 0x5F)) { // _
                return false;
            }
        }

        return true;
    }

    /**
     * @notice Convert string to lowercase bytes32 hash
     * @param str String to hash
     * @return Hash of lowercase string
     */
    function toNameHash(string memory str) internal pure returns (bytes32) {
        bytes memory strBytes = bytes(str);
        bytes memory lowerBytes = new bytes(strBytes.length);

        for (uint256 i = 0; i < strBytes.length; i++) {
            bytes1 char = strBytes[i];
            if (char >= 0x41 && char <= 0x5A) {
                // Convert uppercase to lowercase
                lowerBytes[i] = bytes1(uint8(char) + 32);
            } else {
                lowerBytes[i] = char;
            }
        }

        return keccak256(lowerBytes);
    }
}

