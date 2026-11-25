// Consecutive per-lane VGPR writes all observe the same EXEC bit. Keep them in
// one predicated region. Resource, control-flow and mask-changing statements
// always close the region before they execute.
fn assignment(line: &str) -> Option<&str> {
    let assignment = line.strip_prefix("    if (exec_lo & 1u) ")?;
    let (dest, expr) = assignment.strip_suffix(';')?.split_once(" = ")?;
    let reg = dest.strip_prefix('v')?;
    if reg.is_empty()
        || !reg.bytes().all(|c| c.is_ascii_digit())
        || expr.contains(['[', ']', ';', '{', '}'])
        || expr.contains("++")
        || expr.contains("--")
    {
        return None;
    }
    // Only scalar temporaries, register components, literals and named pure
    // ALU helpers. In particular, no indexed, method, atomic or wave access.
    for token in expr
        .split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
        .filter(|s| !s.is_empty())
    {
        let first = token.as_bytes()[0];
        if first.is_ascii_digit()
            || matches!(
                token,
                "x" | "y"
                    | "z"
                    | "w"
                    | "vcc_lo"
                    | "vcc_hi"
                    | "tb_fp_mode"
                    | "float"
                    | "int"
                    | "uint"
                    | "asuint"
                    | "asfloat"
                    | "asint"
                    | "dot4add_i8packed"
                    | "tb_mull"
                    | "rsqrt"
                    | "sqrt"
                    | "f16tof32"
                    | "max"
                    | "min"
                    | "tb_mulhi_u32"
                    | "abs"
                    | "floor"
                    | "trunc"
                    | "sin"
                    | "tb_mode_half"
                    | "tb_f16_rne"
                    | "saturate"
                    | "ceil"
            )
        {
            continue;
        }
        let Some(tail) = token
            .strip_prefix("tb_s")
            .or_else(|| token.strip_prefix(['t', 'v', 's']))
        else {
            return None;
        };
        if !tail.as_bytes().first().is_some_and(u8::is_ascii_digit)
            || !tail
                .bytes()
                .all(|c| c.is_ascii_digit() || matches!(c, b'a' | b'b' | b'_'))
        {
            return None;
        }
    }
    Some(assignment)
}

pub(super) fn group(body: &str) -> String {
    use std::fmt::Write;
    let mut output = String::with_capacity(body.len());
    let mut open = false;
    for line in body.lines() {
        if let Some(write) = assignment(line) {
            if !open {
                output.push_str("    if (exec_lo & 1u) {\n");
                open = true;
            }
            writeln!(output, "        {write}").unwrap();
        } else {
            if open && !line.trim_start().starts_with("//") {
                output.push_str("    }\n");
                open = false;
            }
            writeln!(output, "{line}").unwrap();
        }
    }
    if open {
        output.push_str("    }\n");
    }
    output
}

#[cfg(test)]
mod tests {
    use super::group;
    use crate::{ShaderExtract, Stage};

    fn compute_extract(words: &[u32]) -> ShaderExtract {
        let isa: Vec<u8> = words.iter().flat_map(|w| w.to_le_bytes()).collect();
        ShaderExtract { flat_inputs: Vec::new(), flat_outputs: Vec::new(),
            stage: Stage::Compute, shader_model: (6, 0), required_features: None,
            bitcode_stripped: true, fspx_config: None, ps09_pixel_inputs: None,
            fssm: Vec::new(), entry: Some("main".into()), isa_data: isa.clone(),
            isa, isa_offset_in_fssm: 0, psv_threads: None, isa_preamble: [0, 64, 1, 1],
            has_input_sig: false, has_output_sig: false, has_psv0: false, has_root_sig: false,
            input_sig: Vec::new(), output_sig: Vec::new(), resources: Vec::new(),
            gs_info: None, mesh_info: None, primitive_sig: Vec::new(), root_sig: None,
        }
    }

    #[test]
    fn bitwise_quad_exchange_combines_the_selected_source_with_the_local_operand() {
        for (op, symbol) in [(0x3808_04fa, "|"), (0x3608_04fa, "&"), (0x3a08_04fa, "^")] {
            for control in [0xff0c_b101, 0xff04_b101] {
                let mut ex = compute_extract(&[op, control, 0xbf81_0000]);
                let hlsl = super::super::translate(&ex).unwrap().hlsl;
                assert!(hlsl.contains("WaveReadLaneAt(v1,"), "{hlsl}");
                assert!(hlsl.contains(&format!("v4 = q0 {symbol} v2;")), "{hlsl}");

                ex.psv_threads = Some([1, 1, 1]);
                assert!(super::super::translate(&ex).is_err());
            }
        }
    }

    #[test]
    fn bitwise_quad_exchange_with_inactive_source_obeys_bound_control() {
        // gfx1030: v_{or,and,xor}_b32_dpp v4, v1, v2 quad_perm:[1,0,3,2], FI=0.
        for (op, symbol) in [(0x3808_04fa, "|"), (0x3608_04fa, "&"), (0x3a08_04fa, "^")] {
            let ex = compute_extract(&[op, 0xff00_b101, 0xbf81_0000]);
            let keep = super::super::translate(&ex).unwrap().hlsl;
            assert!(keep.contains("WaveReadLaneAt(uint2(v1, exec_lo & 1u),"), "{keep}");
            assert!(keep.contains(&format!("q0active ? (q0 {symbol} v2) : v4")), "{keep}");

            let ex = compute_extract(&[op, 0xff08_b101, 0xbf81_0000]);
            let zero = super::super::translate(&ex).unwrap().hlsl;
            assert!(zero.contains("WaveReadLaneAt((exec_lo & 1u) != 0u ? v1 : 0u,"), "{zero}");
            assert!(zero.contains(&format!("v4 = q0 {symbol} v2;")), "{zero}");
        }
    }

    #[test]
    fn compute_register_writes_share_one_exec_region() {
        // v_add_nc_u32 v1, v0, v0; v_add_nc_u32 v2, v1, v1; s_endpgm
        let ex = compute_extract(&[0x4a02_0100, 0x4a04_0301, 0xbf81_0000]);
        let hlsl = super::super::translate(&ex).unwrap().hlsl;
        assert_eq!(hlsl.matches("if (exec_lo & 1u)").count(), 1, "{hlsl}");
        assert!(hlsl.contains("    if (exec_lo & 1u) {\n        v1 = "), "{hlsl}");
        assert!(hlsl.contains("\n        v2 = "), "{hlsl}");
    }

    #[test]
    fn adjacent_pixel_register_writes_keep_order_and_exec_boundaries() {
        const GUARD: &str = "    if (exec_lo & 1u) ";
        let first = format!("{GUARD}v3 = asuint(asfloat(v2) + 1.0);");
        let second = format!("{GUARD}v2 = asuint(max(asfloat(v3), 0.0));");
        let grouped = "    if (exec_lo & 1u) {\n        v3 = asuint(asfloat(v2) + 1.0);\n        v2 = asuint(max(asfloat(v3), 0.0));\n    }\n";
        // Each instruction separates two runs of pure ALU. In particular,
        // derivatives and quad/wave operations must see their original EXEC.
        for boundary in [
            "    exec_lo = s4;",
            "    if (!exec_lo) { discard; }",
            "    if (jT) {",
            "    }",
            "    if (exec_lo & 1u) v3 = QuadReadLaneAt(v2, 1u);",
            "    if (exec_lo & 1u) v3 = WaveActiveSum(v2);",
            "    if (exec_lo & 1u) v3 = asuint(ddx(asfloat(v2)));",
            "    if (exec_lo & 1u) v3 = tex.Load(v2);",
            "    if (exec_lo & 1u) v3 = cache[v2];",
            "    if (exec_lo & 1u) InterlockedAdd(cache[v2], v3);",
            "    if (exec_lo & 1u) target.x = v3;",
        ] {
            let body = format!("{first}\n{second}\n{boundary}\n{first}\n{second}\n");
            assert_eq!(group(&body), format!("{grouped}{boundary}\n{grouped}"));
        }
    }
}
