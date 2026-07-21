shader_type spatial;
render_mode shading_model_pbr, blend_mix, cull_disabled;

uniform sampler2D tex_diffuse : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 param_color = vec4(0.0);
uniform float param_emmisive_str = 0.0;

void fragment() {
    vec4 tex_diffuse_value = texture(tex_diffuse, UV);
    ALBEDO = vec3(1.0);
    ALPHA = 1.0;
    ROUGHNESS = clamp(0.5, 0.0, 1.0);
    METALLIC = clamp(0.0, 0.0, 1.0);
    AO = clamp(1.0, 0.0, 1.0);
    EMISSION = (((vec4((tex_diffuse_value).rgb, 1.0) * vec4((param_color).rgb, 1.0)) * vec4(param_emmisive_str))).rgb;
}
