//! In-process room resolve for Android (app UID + shared TLS stack).
//!
//! JNI symbol: `Java_com_example_livecatch_1app_MainActivity_nativeResolve`

use jni::JNIEnv;
use jni::objects::{JClass, JString};
use jni::sys::jstring;
use std::sync::OnceLock;
use tokio::runtime::Runtime;

fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("lixh-resolve")
            .build()
            .expect("tokio runtime for Android resolve")
    })
}

fn resolve_payload(url: &str, cookies: Option<&str>) -> String {
    match runtime().block_on(crate::resolve(url, cookies, None)) {
        Ok(resolved) => match serde_json::to_string(&resolved) {
            Ok(json) => format!("OK:{json}"),
            Err(e) => format!("ERR:serialize: {e}"),
        },
        Err(e) => format!("ERR:{e:#}"),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_example_livecatch_1app_MainActivity_nativeResolve<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    url: JString<'local>,
    cookies: JString<'local>,
) -> jstring {
    let url = match env.get_string(&url) {
        Ok(s) => String::from(s),
        Err(e) => {
            return env
                .new_string(format!("ERR:bad url: {e}"))
                .map(|s| s.into_raw())
                .unwrap_or(std::ptr::null_mut());
        }
    };

    let cookies = match env.get_string(&cookies) {
        Ok(s) => {
            let v = String::from(s);
            if v.is_empty() {
                None
            } else {
                Some(v)
            }
        }
        Err(_) => None,
    };

    let payload = resolve_payload(&url, cookies.as_deref());
    env.new_string(payload)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}
