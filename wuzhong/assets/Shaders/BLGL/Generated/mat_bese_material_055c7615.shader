shader_type spatial;
render_mode shading_model_pbr, cull_back;

uniform sampler2D tex_base_color : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_emissive : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_srmh : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float param_tesselation = 0.0;
uniform float param_roughness = 0.0;
uniform float param_metall_roughness = 0.0;
uniform float param_metallic = 0.0;

void fragment() {
    vec4 tex_base_color_value = texture(tex_base_color, UV);
    vec4 tex_emissive_value = texture(tex_emissive, UV);
    vec4 tex_srmh_value = texture(tex_srmh, ((vec4(UV, 0.0, 1.0) * vec4(param_tesselation))).rg);
    vec4 tex_normal_value = texture(tex_normal, UV);
    ALBEDO = (tex_base_color_value).rgb;
    ROUGHNESS = clamp(mix(((vec4((tex_srmh_value).g) + vec4(param_roughness))).r, ((vec4((tex_srmh_value).g) + vec4(param_metall_roughness))).r, (tex_srmh_value).b), 0.0, 1.0);
    METALLIC = clamp(((vec4((tex_srmh_value).b) + vec4(param_metallic))).r, 0.0, 1.0);
    AO = clamp(1.0, 0.0, 1.0);
    NORMAL_MAP = (tex_normal_value).rgb;
    EMISSION = (tex_emissive_value).rgb;
}
