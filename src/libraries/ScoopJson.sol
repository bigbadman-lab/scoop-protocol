// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ScoopJson
 * @notice Minimal JSON string escaping + data-URI helpers for ScoopToken.contractURI().
 * @dev Presentation only. Escapes for valid JSON serialization; does not sanitize content.
 */
library ScoopJson {
    /// @dev Escape a UTF-8 string for inclusion inside a JSON string literal.
    function escape(string memory input) internal pure returns (string memory) {
        bytes memory src = bytes(input);
        // Worst case: every byte becomes `\u00XX` (6 bytes).
        bytes memory buf = new bytes(src.length * 6);
        uint256 j;
        for (uint256 i; i < src.length; ++i) {
            uint8 c = uint8(src[i]);
            if (c == 0x22) {
                // "
                buf[j++] = 0x5c;
                buf[j++] = 0x22;
            } else if (c == 0x5c) {
                // \
                buf[j++] = 0x5c;
                buf[j++] = 0x5c;
            } else if (c == 0x08) {
                buf[j++] = 0x5c;
                buf[j++] = 0x62; // \b
            } else if (c == 0x0c) {
                buf[j++] = 0x5c;
                buf[j++] = 0x66; // \f
            } else if (c == 0x0a) {
                buf[j++] = 0x5c;
                buf[j++] = 0x6e; // \n
            } else if (c == 0x0d) {
                buf[j++] = 0x5c;
                buf[j++] = 0x72; // \r
            } else if (c == 0x09) {
                buf[j++] = 0x5c;
                buf[j++] = 0x74; // \t
            } else if (c < 0x20) {
                // \u00XX
                buf[j++] = 0x5c;
                buf[j++] = 0x75;
                buf[j++] = 0x30;
                buf[j++] = 0x30;
                buf[j++] = _hexNibble(c >> 4);
                buf[j++] = _hexNibble(c & 0x0f);
            } else {
                // Preserve normal ASCII and UTF-8 continuation/lead bytes as-is.
                buf[j++] = bytes1(c);
            }
        }
        bytes memory out = new bytes(j);
        for (uint256 k; k < j; ++k) {
            out[k] = buf[k];
        }
        return string(out);
    }

    /// @dev Build `data:application/json;utf8,{...}` with required fields; omit external_link if empty.
    function tokenContractUri(
        string memory name_,
        string memory symbol_,
        string memory description_,
        string memory image_,
        string memory website_
    ) internal pure returns (string memory) {
        string memory body = string(
            abi.encodePacked(
                '{"name":"',
                escape(name_),
                '","symbol":"',
                escape(symbol_),
                '","description":"',
                escape(description_),
                '","image":"',
                escape(image_),
                '"'
            )
        );
        if (bytes(website_).length != 0) {
            body = string(abi.encodePacked(body, ',"external_link":"', escape(website_), '"'));
        }
        body = string(abi.encodePacked(body, "}"));
        return string(abi.encodePacked("data:application/json;utf8,", body));
    }

    function _hexNibble(uint8 n) private pure returns (bytes1) {
        return bytes1(n < 10 ? (0x30 + n) : (0x61 + (n - 10)));
    }
}
