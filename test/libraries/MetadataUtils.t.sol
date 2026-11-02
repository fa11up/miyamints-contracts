// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/shared/libraries/MetadataUtils.sol";

/**
 * @title MetadataUtilsTest
 * @notice Comprehensive unit tests for MetadataUtils library
 */
contract MetadataUtilsTest is Test {
    // Helper contract to test internal library functions
    using MetadataUtils for string;

    /*//////////////////////////////////////////////////////////////
                            isValidURI() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_isValidURI_WithHTTPScheme() public pure {
        string memory uri = "http://example.com/metadata.json";
        assertTrue(MetadataUtils.isValidURI(uri), "HTTP URI should be valid");
    }

    function test_isValidURI_WithHTTPSScheme() public pure {
        string memory uri = "https://example.com/metadata.json";
        assertTrue(MetadataUtils.isValidURI(uri), "HTTPS URI should be valid");
    }

    function test_isValidURI_WithIPFSScheme() public pure {
        string memory uri = "ipfs://QmXnnyufdzAWL5CqZ2RnSNgPbvCc1ALT73s6epPrRnZ1Xy";
        assertTrue(MetadataUtils.isValidURI(uri), "IPFS URI should be valid");
    }

    function test_isValidURI_WithARScheme() public pure {
        string memory uri = "ar://abc123def456";
        assertTrue(MetadataUtils.isValidURI(uri), "Arweave URI should be valid");
    }

    function test_isValidURI_WithInvalidScheme() public pure {
        string memory uri = "ftp://example.com/file.txt";
        assertFalse(MetadataUtils.isValidURI(uri), "FTP URI should be invalid");
    }

    function test_isValidURI_WithEmptyString() public pure {
        string memory uri = "";
        assertFalse(MetadataUtils.isValidURI(uri), "Empty string should be invalid");
    }

    function test_URI_WithComplexURL() public pure {
        string memory uri = "https://api.example.com/v1/nft/metadata?tokenId=123&format=json";
        assertTrue(MetadataUtils.isValidURI(uri), "Complex URL with query params should be valid");
    }

    /*//////////////////////////////////////////////////////////////
                          isValidName() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_isValidName_WithValidAlphanumeric() public pure {
        string memory name = "ValidName123";
        assertTrue(MetadataUtils.isValidName(name), "Alphanumeric name should be valid");
    }

    function test_isValidName_WithHyphens() public pure {
        string memory name = "valid-name";
        assertTrue(MetadataUtils.isValidName(name), "Name with hyphens should be valid");
    }

    function test_isValidName_WithUnderscores() public pure {
        string memory name = "valid_name";
        assertTrue(MetadataUtils.isValidName(name), "Name with underscores should be valid");
    }

    function test_isValidName_TooShort() public pure {
        string memory name = "";
        assertFalse(MetadataUtils.isValidName(name), "Empty name should be invalid");
    }

    function test_isValidName_TooLong() public pure {
        // Create a 65-character string
        string memory name = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklm";
        assertFalse(MetadataUtils.isValidName(name), "Name longer than 64 chars should be invalid");
    }

    function test_isValidName_WithInvalidCharacters() public pure {
        string memory name = "invalid name";
        assertFalse(MetadataUtils.isValidName(name), "Name with spaces should be invalid");
    }

    function test_isValidName_WithSpecialCharacters() public pure {
        string memory name = "invalid@name!";
        assertFalse(MetadataUtils.isValidName(name), "Name with special characters should be invalid");
    }

    function test_isValidName_At64CharBoundary() public pure {
        // Create exactly 64-character string
        string memory name = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghij";
        assertTrue(MetadataUtils.isValidName(name), "Name with exactly 64 chars should be valid");
    }

    function test_isValidName_At65CharBoundary() public pure {
        // Create exactly 65-character string
        string memory name = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklm";
        assertFalse(MetadataUtils.isValidName(name), "Name with exactly 65 chars should be invalid");
    }

    function test_isValidName_MixedCharacters() public pure {
        string memory name = "Valid_Name-123";
        assertTrue(MetadataUtils.isValidName(name), "Name with mixed valid characters should be valid");
    }

    /*//////////////////////////////////////////////////////////////
                          startsWith() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_startsWith_WithMatchingPrefix() public pure {
        string memory str = "https://example.com";
        string memory prefix = "https://";
        assertTrue(MetadataUtils.startsWith(str, prefix), "String should start with matching prefix");
    }

    function test_startsWith_WithNonMatchingPrefix() public pure {
        string memory str = "https://example.com";
        string memory prefix = "http://";
        assertFalse(MetadataUtils.startsWith(str, prefix), "String should not start with non-matching prefix");
    }

    function test_startsWith_WithEmptyPrefix() public pure {
        string memory str = "any string";
        string memory prefix = "";
        assertTrue(MetadataUtils.startsWith(str, prefix), "Any string should start with empty prefix");
    }

    function test_startsWith_WithPrefixLongerThanString() public pure {
        string memory str = "short";
        string memory prefix = "much longer prefix";
        assertFalse(MetadataUtils.startsWith(str, prefix), "String should not start with longer prefix");
    }

    /*//////////////////////////////////////////////////////////////
                          toNameHash() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_toNameHash_ConvertsUppercaseToLowercase() public pure {
        string memory upperName = "TESTNAME";
        string memory lowerName = "testname";

        bytes32 upperHash = MetadataUtils.toNameHash(upperName);
        bytes32 lowerHash = MetadataUtils.toNameHash(lowerName);

        assertEq(upperHash, lowerHash, "Uppercase should be converted to lowercase before hashing");
    }

    function test_toNameHash_PreservesLowercaseAndNumbers() public pure {
        string memory name = "test123name";

        bytes32 hash1 = MetadataUtils.toNameHash(name);
        bytes32 hash2 = MetadataUtils.toNameHash(name);

        assertEq(hash1, hash2, "Same lowercase/number string should produce same hash");
        assertEq(hash1, keccak256(bytes(name)), "Lowercase name hash should match direct keccak256");
    }

    function test_toNameHash_CaseInsensitiveComparison() public pure {
        string memory mixedCase = "TeSt";
        string memory lowercase = "test";

        bytes32 mixedHash = MetadataUtils.toNameHash(mixedCase);
        bytes32 lowerHash = MetadataUtils.toNameHash(lowercase);

        assertEq(mixedHash, lowerHash, "Mixed case and lowercase should produce same hash");
    }

    function test_toNameHash_WithComplexMixedCase() public pure {
        string memory name1 = "MyTokenName123";
        string memory name2 = "mytokenname123";
        string memory name3 = "MYTOKENNAME123";

        bytes32 hash1 = MetadataUtils.toNameHash(name1);
        bytes32 hash2 = MetadataUtils.toNameHash(name2);
        bytes32 hash3 = MetadataUtils.toNameHash(name3);

        assertEq(hash1, hash2, "Different cases should produce same hash (1-2)");
        assertEq(hash2, hash3, "Different cases should produce same hash (2-3)");
        assertEq(hash1, hash3, "Different cases should produce same hash (1-3)");
    }
}
