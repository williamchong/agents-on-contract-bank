// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @dev An RSA-2048 key and its signature over the SHA-256 of the 32-byte digest
/// sha256("spike partner digest"), which is what ERC7913RSAVerifier checks. Made with:
///   openssl genrsa -out rsa.pem 2048
///   printf 'spike partner digest' | openssl dgst -sha256 -binary > digest.bin
///   openssl dgst -sha256 -sign rsa.pem -out sig.bin digest.bin
library RsaVector {
    bytes32 internal constant DIGEST = sha256("spike partner digest");
    bytes internal constant E = hex"010001";
    bytes internal constant N =
        hex"8dfa31a9a25615403e48b49559d11682fd87ddbad0711e7920d598dcfb23191361bb2982dc9393fcc0a92d25b1c50256995a0633f21488a589e450360fbc4a93772ed8f9dc91cef287b938c694238a9dda1a87c9de47741b43f5d52969fb96680ff84f65f8779fbcaa3eac0ba0eecf579b564949a628c9fe6c112b9a7c430d3e9cf0b4cdd47862744aee3538513ebb5bd44e1a872aeedefd2200fa7e3019942a17bc2b1e9cccaf3463f34d6a9c82f6fd38561490876861952f6d02832428cfbb7bffb02e3b49412719e28b9139a11742f9bae42c202d3c7c768490bf679d31d166c3016d4b704f7062062210ae638997592f9cb4661fe4066103e1629f05a91f";
    bytes internal constant SIG =
        hex"8003546d55c61493df39b0d0825cbfa44a7f6381c38afba29e90e5be80857ec73d021b4df64e7de6bbcb8ddffb7eb2de14f3e9c9e84ae6c04343bb1ea125ced47495c507a168c57b41798a478b3361b057203ca5bc36d8dbf59748f608105c213b7bbe0944354f8431c5a250df81d18ee49fbe01ecf05ea39f34af4f9bfc4e0930ebaf47a9f3f66cb2c27d2daf7711e932afc044835d31dc18aeda28a3b1c6633e81c7f95c143749bc8d8384c450d92d8e8ab1626c25b26be67ad22454db91d68250942ecf0fdb6d8d00998e05dd907dbf7f17d3a7f6bbc1e257e0a730212ad4885edba121e072c048ed6b74428136023e8184f22e3a7e29294c67ad4d2f85b5";
}
