shader_type spatial;
render_mode shading_model_pbr, cull_back;

uniform sampler2D tex_base_color : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float param_roughness = 0.0;
uniform float param_metallic = 0.0;

void fragment() {
    vec4 tex_base_color_value = texture(tex_base_color, UV);
    vec4 tex_normal_value = texture(tex_normal, UV);
    ALBEDO = (tex_base_color_value).rgb;
    ROUGHNESS = clamp(param_roughness, 0.0, 1.0);
    METALLIC = clamp(param_metallic, 0.0, 1.0);
    AO = clamp(1.0, 0.0, 1.0);
    NORMAL_MAP = (tex_normal_value).rgb;
    EMISSION = vec3(0.0);
}
