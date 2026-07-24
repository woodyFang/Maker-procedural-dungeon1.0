shader_type spatial;
render_mode shading_model_pbr, blend_mix, cull_disabled;

uniform sampler2D tex_base_color : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_emissive : source_color, filter_linear_mipmap, repeat_enable;

void fragment() {
    vec4 tex_base_color_value = texture(tex_base_color, UV);
    vec4 tex_emissive_value = texture(tex_emissive, UV);
    ALBEDO = (tex_base_color_value).rgb;
    ALPHA = 1.0;
    ROUGHNESS = clamp(0.5, 0.0, 1.0);
    METALLIC = clamp(0.0, 0.0, 1.0);
    AO = clamp(1.0, 0.0, 1.0);
    EMISSION = (tex_emissive_value).rgb;
}
