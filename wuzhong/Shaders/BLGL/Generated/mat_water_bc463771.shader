shader_type spatial;
render_mode shading_model_pbr, blend_mix, cull_back;

uniform sampler2D tex_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 param_color = vec4(0.0);
uniform float param_opacity = 0.0;
uniform float param_roughness = 0.0;

void fragment() {
    vec4 tex_normal_value = texture(tex_normal, UV);
    ALBEDO = (param_color).rgb;
    ALPHA = param_opacity;
    ROUGHNESS = clamp(param_roughness, 0.0, 1.0);
    METALLIC = clamp(0.0, 0.0, 1.0);
    AO = clamp(1.0, 0.0, 1.0);
    NORMAL_MAP = (tex_normal_value).rgb;
    EMISSION = vec3(0.0);
}
