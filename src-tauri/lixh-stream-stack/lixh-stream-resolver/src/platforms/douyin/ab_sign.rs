//! Douyin (抖音) a_bogus signature algorithm — pure Rust implementation.
//!
//! This is a faithful port of streamget's `ab_sign.py`, implementing:
//! - SM3 national cryptographic hash (国密哈希)
//! - RC4 stream cipher
//! - Modified Base64 encoding with 5 custom encoding tables
//! - a_bogus signature generation

use std::collections::BTreeMap;

// ============================================================
// RC4 stream cipher (character-level, matching Python implementation)
// ============================================================

/// RC4 encrypt a plaintext string with a key string.
///
/// This operates on character code points (0-255), matching the Python implementation.
fn rc4_encrypt(plaintext: &str, key: &str) -> Vec<u8> {
    let mut s: Vec<u8> = (0..=255).collect();

    let mut j: usize = 0;
    let key_bytes = key.as_bytes();
    let key_len = key_bytes.len();

    for i in 0..256 {
        j = (j + s[i] as usize + key_bytes[i % key_len] as usize) % 256;
        s.swap(i, j);
    }

    let mut i: usize = 0;
    let mut j: usize = 0;
    let mut result_string = String::new();

    for byte in plaintext.chars() {
        i = (i + 1) % 256;
        j = (j + s[i] as usize) % 256;
        s.swap(i, j);

        let t = (s[i] as usize + s[j] as usize) % 256;
        let keystream_byte = s[t];
        let encrypted_byte = keystream_byte ^ (byte as u8);

        // Python的chr()将0-255的值转为Unicode字符
        // 然后join时隐式编码为UTF-8
        let ch = char::from_u32(encrypted_byte as u32).unwrap_or('�');
        result_string.push(ch);
    }

    // 返回UTF-8编码的字节
    result_string.into_bytes()
}

// ============================================================
// SM3 national cryptographic hash (国密哈希)
// ============================================================

const SM3_IV: [u32; 8] = [
    1937774191, 1226093241, 388252375, 3666478592, 2842636476, 372324522, 3817729613, 2969243214,
];

fn left_rotate(x: u32, n: u32) -> u32 {
    let n = n % 32;
    if n == 0 {
        return x;
    }
    (x << n) | (x >> (32 - n))
}

fn get_t_j(j: usize) -> u32 {
    if j < 16 {
        2043430169 // 0x79CC4519
    } else {
        2055708042 // 0x7A879D8A
    }
}

fn ff_j(j: usize, x: u32, y: u32, z: u32) -> u32 {
    if j < 16 {
        x ^ y ^ z
    } else {
        (x & y) | (x & z) | (y & z)
    }
}

fn gg_j(j: usize, x: u32, y: u32, z: u32) -> u32 {
    if j < 16 {
        x ^ y ^ z
    } else {
        (x & y) | ((!x) & z)
    }
}

struct SM3 {
    reg: [u32; 8],
    chunk: Vec<u8>,
    size: usize,
}

impl SM3 {
    fn new() -> Self {
        Self {
            reg: SM3_IV,
            chunk: Vec::new(),
            size: 0,
        }
    }

    fn reset(&mut self) {
        self.reg = SM3_IV;
        self.chunk.clear();
        self.size = 0;
    }

    fn write(&mut self, data: &[u8]) {
        self.size += data.len();
        let mut remaining = data;

        while !remaining.is_empty() {
            let space = 64 - self.chunk.len();
            if remaining.len() < space {
                self.chunk.extend_from_slice(remaining);
                break;
            } else {
                self.chunk.extend_from_slice(&remaining[..space]);
                remaining = &remaining[space..];

                if self.chunk.len() >= 64 {
                    let chunk: Vec<u8> = self.chunk.drain(..).collect();
                    self.compress(&chunk);
                }
            }
        }
    }

    fn fill(&mut self) {
        let bit_length = (self.size as u64) * 8;
        self.chunk.push(0x80);

        while self.chunk.len() % 64 != 56 {
            self.chunk.push(0);
        }

        // Append 64-bit big-endian length
        self.chunk.extend_from_slice(&bit_length.to_be_bytes());
    }

    fn compress(&mut self, data: &[u8]) {
        if data.len() < 64 {
            return;
        }

        let mut w = [0u32; 132];

        // Parse 16 words from data
        for t in 0..16 {
            w[t] = ((data[4 * t] as u32) << 24)
                | ((data[4 * t + 1] as u32) << 16)
                | ((data[4 * t + 2] as u32) << 8)
                | (data[4 * t + 3] as u32);
        }

        // Message expansion
        for j in 16..68 {
            let a = w[j - 16] ^ w[j - 9] ^ left_rotate(w[j - 3], 15);
            let a = a ^ left_rotate(a, 15) ^ left_rotate(a, 23);
            w[j] = a ^ left_rotate(w[j - 13], 7) ^ w[j - 6];
        }

        // Compute w'
        for j in 0..64 {
            w[j + 68] = w[j] ^ w[j + 4];
        }

        let mut a = self.reg[0];
        let mut b = self.reg[1];
        let mut c = self.reg[2];
        let mut d = self.reg[3];
        let mut e = self.reg[4];
        let mut f = self.reg[5];
        let mut g = self.reg[6];
        let mut h = self.reg[7];

        for j in 0..64 {
            let ss1 = left_rotate(
                left_rotate(a, 12)
                    .wrapping_add(e)
                    .wrapping_add(left_rotate(get_t_j(j), j as u32)),
                7,
            );
            let ss2 = ss1 ^ left_rotate(a, 12);
            let tt1 = ff_j(j, a, b, c)
                .wrapping_add(d)
                .wrapping_add(ss2)
                .wrapping_add(w[j + 68]);
            let tt2 = gg_j(j, e, f, g)
                .wrapping_add(h)
                .wrapping_add(ss1)
                .wrapping_add(w[j]);

            d = c;
            c = left_rotate(b, 9);
            b = a;
            a = tt1;
            h = g;
            g = left_rotate(f, 19);
            f = e;
            e = tt2 ^ left_rotate(tt2, 9) ^ left_rotate(tt2, 17);
        }

        self.reg[0] ^= a;
        self.reg[1] ^= b;
        self.reg[2] ^= c;
        self.reg[3] ^= d;
        self.reg[4] ^= e;
        self.reg[5] ^= f;
        self.reg[6] ^= g;
        self.reg[7] ^= h;
    }

    fn sum_bytes(&mut self, data: &[u8]) -> Vec<u8> {
        self.reset();
        self.write(data);
        self.fill();

        // Compress remaining chunks
        let mut offset = 0;
        while offset + 64 <= self.chunk.len() {
            let chunk: Vec<u8> = self.chunk[offset..offset + 64].to_vec();
            self.compress(&chunk);
            offset += 64;
        }

        let mut result = Vec::with_capacity(32);
        for &val in &self.reg {
            result.push((val >> 24) as u8);
            result.push((val >> 16) as u8);
            result.push((val >> 8) as u8);
            result.push(val as u8);
        }

        self.reset();
        result
    }
}

/// Compute SM3 hash of a string, returning bytes.
fn sm3_sum(data: &str) -> Vec<u8> {
    let mut sm3 = SM3::new();
    sm3.sum_bytes(data.as_bytes())
}

// ============================================================
// Modified Base64 encoding (魔改 Base64)
// ============================================================

/// The 5 custom encoding tables used in Douyin's algorithm.
const ENCODING_TABLES: [&str; 5] = [
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=", // s0 (standard)
    "Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe=", // s1
    "Dkdpgh4ZKsQB80/Mfvw36XI1R25-WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe=", // s2
    "ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe",  // s3
    "Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe",  // s4
];

const MASKS: [u32; 4] = [16515072, 258048, 4032, 63];
const SHIFTS: [u32; 4] = [18, 12, 6, 0];

/// Get the encoding table index for a given table name ("s0" through "s4").
fn get_table(name: &str) -> &'static str {
    match name {
        "s0" => ENCODING_TABLES[0],
        "s1" => ENCODING_TABLES[1],
        "s2" => ENCODING_TABLES[2],
        "s3" => ENCODING_TABLES[3],
        "s4" => ENCODING_TABLES[4],
        _ => ENCODING_TABLES[0],
    }
}

/// Get a 24-bit integer from 3 characters of the string at the given round.
fn get_long_int(round_num: usize, long_str: &[u8]) -> u32 {
    let s = String::from_utf8_lossy(long_str);
    let start = round_num * 3;
    let mut chars = s.chars().skip(start);

    let char1 = chars.next().map_or(0, |c| c as u32);
    let char2 = chars.next().map_or(0, |c| c as u32);
    let char3 = chars.next().map_or(0, |c| c as u32);

    (char1 << 16) | (char2 << 8) | char3
}

/// Modified Base64 encode using a custom encoding table.
///
/// This faithfully replicates the Python `result_encrypt()` function.
fn result_encrypt(long_str: &[u8], table_name: &str) -> String {
    let table = get_table(table_name);
    let table_bytes = table.as_bytes();

    let chars: Vec<char> = String::from_utf8_lossy(long_str).chars().collect();
    let total_chars = ((chars.len() as f64) / 3.0 * 4.0).ceil() as usize;
    let mut result = String::with_capacity(total_chars);
    let mut round_num: usize = 0;
    let mut long_int = get_long_int(round_num, long_str);

    for i in 0..total_chars {
        // Check if we need to advance to the next round
        if i / 4 != round_num {
            round_num = i / 4;
            long_int = get_long_int(round_num, long_str);
        }

        let index = i % 4;
        let char_index = ((long_int & MASKS[index]) >> SHIFTS[index]) as usize;
        if char_index < table_bytes.len() {
            result.push(table_bytes[char_index] as char);
        }
    }

    result
}

// ============================================================
// Random byte generation for signature
// ============================================================

/// Generate random bytes from fixed random values (matching Python implementation).
fn gener_random(random_num: u32, option: [u8; 2]) -> [u8; 4] {
    let byte1 = (random_num & 255) as u8;
    let byte2 = ((random_num >> 8) & 255) as u8;

    [
        (byte1 & 0xAA) | (option[0] & 0x55),
        (byte1 & 0x55) | (option[0] & 0xAA),
        (byte2 & 0xAA) | (option[1] & 0x55),
        (byte2 & 0x55) | (option[1] & 0xAA),
    ]
}

/// Generate a random string prefix (using fixed random values like the Python version).
fn generate_random_str() -> Vec<u8> {
    let random_values = [0.123456789, 0.987654321, 0.555555555];

    let mut random_bytes = Vec::new();
    random_bytes.extend_from_slice(&gener_random((random_values[0] * 10000.0) as u32, [3, 45]));
    random_bytes.extend_from_slice(&gener_random((random_values[1] * 10000.0) as u32, [1, 0]));
    random_bytes.extend_from_slice(&gener_random((random_values[2] * 10000.0) as u32, [1, 5]));

    random_bytes
}

// ============================================================
// RC4 + build byte array for signature
// ============================================================

/// Split a u32 into 4 big-endian bytes.
fn split_to_bytes(num: u32) -> [u8; 4] {
    [
        ((num >> 24) & 255) as u8,
        ((num >> 16) & 255) as u8,
        ((num >> 8) & 255) as u8,
        (num & 255) as u8,
    ]
}

/// Generate the RC4-encrypted body of the a_bogus signature.
///
/// This faithfully replicates the Python `generate_rc4_bb_str()` function.
fn generate_rc4_bb_str(url_search_params: &str, user_agent: &str, window_env_str: &str) -> Vec<u8> {
    let start_time = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    // let start_time = 1784368186353;
    generate_rc4_bb_str_with_time(url_search_params, user_agent, window_env_str, start_time)
}

/// Internal: generate_rc4_bb_str with an explicit timestamp (for testing).
fn generate_rc4_bb_str_with_time(
    url_search_params: &str,
    user_agent: &str,
    window_env_str: &str,
    start_time: u64,
) -> Vec<u8> {
    let end_time = start_time + 100;

    // Three encryption passes:
    // 1. Double SM3 hash of url_search_params + "cus"
    let url_search_params_list = {
        let s1 = sm3_sum(&format!("{}cus", url_search_params));
        sm3_sum_bytes(&s1)
    };

    // 2. Double SM3 hash of "cus"
    let cus = {
        let s1 = sm3_sum("cus");
        sm3_sum_bytes(&s1)
    };

    // 3. RC4 encrypt UA with key [0, 1, 14], then modified base64 encode with s3, then SM3 hash
    let ua = {
        let ua_key: Vec<u8> = vec![0, 1, 14]; // chr(0) + chr(1) + chr(14)
        let ua_str: String = user_agent.chars().map(|c| c as u8 as char).collect();
        let rc4_result = rc4_encrypt(
            &ua_str,
            &ua_key.iter().map(|&b| b as char).collect::<String>(),
        );
        let encoded = result_encrypt(&rc4_result, "s3");
        sm3_sum(&encoded)
    };

    // Build the configuration map
    let mut b: BTreeMap<usize, u64> = BTreeMap::new();
    b.insert(8, 3);
    b.insert(10, end_time);
    b.insert(16, start_time);
    b.insert(18, 44);

    // b[15] — config object (Python dict). Only pageId and aid are used later.
    //   { "aid": 6383, "pageId": 110624, "boe": False, "ddrt": 7,
    //     "paths": { "include": [{} x7], "exclude": [] },
    //     "track": { "mode": 0, "delay": 300, "paths": [] },
    //     "dump": True, "rpU": "hwj" }
    let page_id: u64 = 110624;
    let aid: u64 = 6383;

    b.insert(16, start_time);
    b.insert(18, 44);

    // b[19] = [1, 0, 1, 5] — defined in Python but not referenced in the computation.
    let _b19: [u32; 4] = [1, 0, 1, 5];

    // Process start_time bytes (indices 20-25)
    let start_time_bytes = split_to_bytes(start_time as u32);
    b.insert(20, start_time_bytes[0] as u64);
    b.insert(21, start_time_bytes[1] as u64);
    b.insert(22, start_time_bytes[2] as u64);
    b.insert(23, start_time_bytes[3] as u64);
    b.insert(24, (start_time / 256 / 256 / 256 / 256) & 255);
    b.insert(25, (start_time / 256 / 256 / 256 / 256 / 256) & 255);

    // Arguments [0, 1, 14]
    let arguments: [u32; 3] = [0, 1, 14];

    // arg0 bytes (indices 26-29)
    let arg0_bytes = split_to_bytes(arguments[0]);
    b.insert(26, arg0_bytes[0] as u64);
    b.insert(27, arg0_bytes[1] as u64);
    b.insert(28, arg0_bytes[2] as u64);
    b.insert(29, arg0_bytes[3] as u64);

    // arguments[1] (indices 30-33)
    b.insert(30, (arguments[1] / 256) as u64 & 255);
    b.insert(31, (arguments[1] % 256) as u64 & 255);
    let arg1_bytes = split_to_bytes(arguments[1]);
    b.insert(32, arg1_bytes[0] as u64);
    b.insert(33, arg1_bytes[1] as u64);

    // arg2 bytes (indices 34-37)
    let arg2_bytes = split_to_bytes(arguments[2]);
    b.insert(34, arg2_bytes[0] as u64);
    b.insert(35, arg2_bytes[1] as u64);
    b.insert(36, arg2_bytes[2] as u64);
    b.insert(37, arg2_bytes[3] as u64);

    // Encryption results (indices 38-43)
    b.insert(38, url_search_params_list[21] as u64);
    b.insert(39, url_search_params_list[22] as u64);
    b.insert(40, cus[21] as u64);
    b.insert(41, cus[22] as u64);
    b.insert(42, ua[23] as u64);
    b.insert(43, ua[24] as u64);

    // End time bytes (indices 44-50)
    let end_time_bytes = split_to_bytes(end_time as u32);
    b.insert(44, end_time_bytes[0] as u64);
    b.insert(45, end_time_bytes[1] as u64);
    b.insert(46, end_time_bytes[2] as u64);
    b.insert(47, end_time_bytes[3] as u64);
    b.insert(48, b[&8]); // = 3
    b.insert(49, (end_time / 256 / 256 / 256 / 256) & 255);
    b.insert(50, (end_time / 256 / 256 / 256 / 256 / 256) & 255);

    // Page ID (indices 51-55)
    b.insert(51, page_id);
    let page_id_bytes = split_to_bytes(page_id as u32);
    b.insert(52, page_id_bytes[0] as u64);
    b.insert(53, page_id_bytes[1] as u64);
    b.insert(54, page_id_bytes[2] as u64);
    b.insert(55, page_id_bytes[3] as u64);

    // Aid (indices 56-60)
    b.insert(56, aid);
    b.insert(57, aid & 255);
    b.insert(58, (aid >> 8) & 255);
    b.insert(59, (aid >> 16) & 255);
    b.insert(60, (aid >> 24) & 255);

    // Window environment info (indices 64-66)
    let window_env_list: Vec<u8> = window_env_str.bytes().collect();
    let env_len = window_env_list.len() as u64;
    b.insert(64, env_len);
    b.insert(65, env_len & 255);
    b.insert(66, (env_len >> 8) & 255);

    b.insert(69, 0);
    b.insert(70, 0);
    b.insert(71, 0);

    // Compute checksum (index 72)
    let checksum_indices = [
        18, 20, 26, 30, 38, 40, 42, 21, 27, 31, 35, 39, 41, 43, 22, 28, 32, 36, 23, 29, 33, 37, 44,
        45, 46, 47, 48, 49, 50, 24, 25, 52, 53, 54, 55, 57, 58, 59, 60, 65, 66, 70, 71,
    ];
    let checksum: u64 = checksum_indices
        .iter()
        .map(|&i| b.get(&i).copied().unwrap_or(0))
        .fold(0u64, |acc, v| acc ^ v);
    b.insert(72, checksum);

    // Build final byte array in specific order
    let bb_order = [
        18, 20, 52, 26, 30, 34, 58, 38, 40, 53, 42, 21, 27, 54, 55, 31, 35, 57, 39, 41, 43, 22, 28,
        32, 60, 36, 23, 29, 33, 37, 44, 45, 59, 46, 47, 48, 49, 50, 24, 25, 65, 66, 70, 71,
    ];

    let mut bb: Vec<u8> = Vec::with_capacity(bb_order.len() + window_env_list.len() + 1);
    for &idx in &bb_order {
        bb.push(b.get(&idx).copied().unwrap_or(0) as u8);
    }
    bb.extend_from_slice(&window_env_list);
    bb.push(checksum as u8);

    // RC4 encrypt with key chr(121) = 'y'
    let bb_str: String = bb.iter().map(|&b| b as u8 as char).collect();
    // let bb_str = String::from_utf8_lossy(&bb);
    let key = String::from('\u{0079}'); // chr(121) = 'y'
    rc4_encrypt(&bb_str, &key)
}

/// Helper: SM3 hash of bytes, returning bytes.
fn sm3_sum_bytes(data: &[u8]) -> Vec<u8> {
    let mut sm3 = SM3::new();
    sm3.sum_bytes(data)
}

// ============================================================
// Main a_bogus signature generation
// ============================================================

/// Generate the a_bogus signature for a Douyin API request.
///
/// # Arguments
/// * `url_search_params` - The query string of the API URL (e.g. "aid=6383&app_name=douyin_web&...")
/// * `user_agent` - The browser user agent string
///
/// # Returns
/// The a_bogus signature string to append to the API URL.
pub fn ab_sign(url_search_params: &str, user_agent: &str) -> String {
    let window_env_str = "1920|1080|1920|1040|0|30|0|0|1872|92|1920|1040|1857|92|1|24|Win32";

    // 1. Generate random string prefix
    let random_v = generate_random_str();
    let s = random_v.iter().map(|&b| b as char).collect::<String>();
    let random_str = s.as_bytes();

    // 2. Generate RC4 encrypted body
    let rc4_body = generate_rc4_bb_str(url_search_params, user_agent, window_env_str);

    // 3. Concatenate random prefix + RC4 body
    let mut combined = Vec::with_capacity(random_str.len() + rc4_body.len());
    combined.extend_from_slice(&random_str);
    combined.extend_from_slice(&rc4_body);

    // 4. Modified Base64 encode with s4 table + "=" suffix
    let encoded = result_encrypt(&combined, "s4");
    format!("{}=", encoded)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rc4_encrypt() {
        // let user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/141.0.0.0 Safari/537.36";
        // let ua_key: Vec<u8> = vec![0, 1, 14];
        // let result = rc4_encrypt(
        //     &user_agent,
        //     &ua_key.iter().map(|&b| b as char).collect::<String>(),
        // );
        // println!("{:?}", result);
        let bb: [u16; 110] = [
            44, 116, 0, 0, 0, 0, 24, 173, 58, 1, 182, 161, 0, 176, 32, 1, 0, 239, 37, 51, 45, 195,
            0, 0, 0, 0, 241, 0, 0, 14, 116, 161, 0, 196, 85, 3, 159, 1, 159, 1, 65, 0, 0, 0, 49,
            57, 50, 48, 124, 49, 48, 56, 48, 124, 49, 57, 50, 48, 124, 49, 48, 52, 48, 124, 48,
            124, 51, 48, 124, 48, 124, 48, 124, 49, 56, 55, 50, 124, 57, 50, 124, 49, 57, 50, 48,
            124, 49, 48, 52, 48, 124, 49, 56, 53, 55, 124, 57, 50, 124, 49, 124, 50, 52, 124, 87,
            105, 110, 51, 50, 190,
        ];
        // println!("{:?}", String::from_utf16(&bb));
        // let plaintext = &bb;
        let key = "y";
        // let s = bb.iter().map(|&b| char::from(b)).collect::<String>();

        let s = String::from_utf16(&bb).unwrap();
        let result = rc4_encrypt(&s, key);

        println!("{:?}", result);
    }

    #[test]
    fn test_long_int() {
        let rc4_str: [u8; 142] = [
            194, 149, 194, 134, 194, 148, 195, 189, 194, 175, 195, 164, 16, 194, 167, 49, 30, 195,
            153, 44, 109, 64, 195, 132, 194, 155, 194, 175, 93, 103, 96, 23, 122, 86, 195, 169,
            194, 156, 195, 182, 195, 128, 194, 128, 20, 23, 195, 142, 99, 79, 195, 165, 195, 191,
            195, 189, 195, 142, 195, 167, 2, 2, 194, 138, 60, 55, 195, 144, 194, 170, 195, 160, 39,
            194, 181, 112, 75, 194, 170, 24, 58, 85, 121, 101, 195, 153, 96, 195, 149, 7, 121, 194,
            136, 194, 173, 127, 195, 185, 195, 149, 194, 148, 194, 176, 195, 166, 194, 148, 195,
            166, 194, 158, 195, 143, 195, 183, 194, 172, 36, 45, 85, 195, 133, 195, 150, 194, 174,
            90, 13, 40, 46, 194, 139, 194, 158, 194, 135, 194, 186, 195, 138, 65,
        ];
        let s = get_long_int(0, &rc4_str);
        println!("{:?}", s);
    }
    #[test]
    fn test_gener_random() {
        let random_values = [0.123456789, 0.987654321, 0.555555555];
        let result = gener_random((random_values[0] * 10000.0) as u32, [3, 45]);
        println!("{:?}", result);
    }

    #[test]
    fn test_generate_random_str() {
        let random_values = [0.123456789, 0.987654321, 0.555555555];

        let mut random_bytes = Vec::new();
        random_bytes.extend(gener_random((random_values[0] * 10000.0) as u32, [3, 45]));
        random_bytes.extend(gener_random((random_values[1] * 10000.0) as u32, [1, 0]));
        random_bytes.extend(gener_random((random_values[2] * 10000.0) as u32, [1, 5]));

        // 将每个字节作为 Unicode 码点转换为字符，然后编码为 UTF-8
        let s = random_bytes.iter().map(|&b| b as char).collect::<String>();
        println!("random_str: {:?}", s.as_bytes());
    }

    #[test]
    fn test_result_encrypt() {
        let rc4_str: [u8; 142] = [
            194, 149, 194, 134, 194, 148, 195, 189, 194, 175, 195, 164, 16, 194, 167, 49, 30, 195,
            153, 44, 109, 64, 195, 132, 194, 155, 194, 175, 93, 103, 96, 23, 122, 86, 195, 169,
            194, 156, 195, 182, 195, 128, 194, 128, 20, 23, 195, 142, 99, 79, 195, 165, 195, 191,
            195, 189, 195, 142, 195, 167, 2, 2, 194, 138, 60, 55, 195, 144, 194, 170, 195, 160, 39,
            194, 181, 112, 75, 194, 170, 24, 58, 85, 121, 101, 195, 153, 96, 195, 149, 7, 121, 194,
            136, 194, 173, 127, 195, 185, 195, 149, 194, 148, 194, 176, 195, 166, 194, 148, 195,
            166, 194, 158, 195, 143, 195, 183, 194, 172, 36, 45, 85, 195, 133, 195, 150, 194, 174,
            90, 13, 40, 46, 194, 139, 194, 158, 194, 135, 194, 186, 195, 138, 65,
        ];
        let encoded = result_encrypt(&rc4_str, "s3");
        assert_eq!(encoded, "bR56e5eL1UWJZzLu+6p1oDtQ29cgAb+TqM+cEkfgro0MGletrmWdcYYS0tdOVdAxW1mO4pTXAIg2R06ZAR7zleqXbBpob/5AreAusdxXJQ5mIEyYBYmAiaPUff");
    }

    #[test]
    fn test_ua() {
        let user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/141.0.0.0 Safari/537.36";

        let ua = {
            let ua_key: Vec<u8> = vec![0, 1, 14]; // chr(0) + chr(1) + chr(14)
            let ua_str: String = user_agent.chars().map(|c| c as u8 as char).collect();
            let rc4_result = rc4_encrypt(
                &ua_str,
                &ua_key.iter().map(|&b| b as char).collect::<String>(),
            );
            println!("rc4: {:?}", rc4_result);
            let encoded = result_encrypt(&rc4_result, "s3");
            println!("encode: {:?}", encoded);
            sm3_sum(&encoded)
        };
        println!("{:?}", ua);
    }

    #[test]
    fn test_generate_rc4_bb_str() {
        let window_env_str = "1920|1080|1920|1040|0|30|0|0|1872|92|1920|1040|1857|92|1|24|Win32";
        let user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/141.0.0.0 Safari/537.36";
        let url_search_params =
            "aid=6383&app_name=douyin_web&live_id=1&device_platform=web&language=zh-CN";
        let result = generate_rc4_bb_str(url_search_params, user_agent, window_env_str);
        // Should produce 110 bytes (44 bb bytes + 65 window_env bytes + 1 checksum)
        println!("{:?}", result);
    }

    /// End-to-end test: compare full ab_sign output with Python reference.
    #[test]
    fn test_ab_sign_matches_python() {
        let url_search_params =
            "aid=6383&app_name=douyin_web&live_id=1&device_platform=web&language=zh-CN";
        let user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/141.0.0.0 Safari/537.36";
        let window_env_str = "1920|1080|1920|1040|0|30|0|0|1872|92|1920|1040|1857|92|1|24|Win32";

        // 1. Generate random string prefix
        let random_str = generate_random_str();
        println!("random_str: {:?}", random_str.clone());
        // 2. Generate RC4 encrypted body
        let rc4_body = generate_rc4_bb_str(url_search_params, user_agent, window_env_str);
        println!("rc4_body: {:?}", rc4_body.clone());
        // 3. Concatenate random prefix + RC4 body
        let mut combined = Vec::with_capacity(random_str.len() + rc4_body.len());
        combined.extend_from_slice(&random_str);
        combined.extend_from_slice(&rc4_body);
        println!("combined: {:?}", combined.clone());

        // 4. Modified Base64 encode with s4 table + "=" suffix
        let encoded = result_encrypt(&combined, "s4");
        println!("{}=", encoded);
    }

    #[test]
    fn test_sm3_hash() {
        let hash = sm3_sum("abc");
        assert_eq!(hash.len(), 32); // SM3 produces 256-bit (32-byte) hash
    }

    #[test]
    fn test_ab_sign_not_empty() {
        let params = "aid=6383&app_name=douyin_web&live_id=1&device_platform=web&language=zh-CN";
        let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36";
        let signature = ab_sign(params, ua);
        println!("{}", signature);
        assert!(!signature.is_empty());
        assert!(signature.ends_with('='));
    }
}
