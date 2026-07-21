shader_type spatial;
render_mode shading_model_pbr, cull_back;

uniform sampler2D tex_base_color : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_t_default_material_grid_n : hint_normal, filter_linear_mipmap, repeat_enable;

void fragment() {
    vec4 tex_base_color_value = texture(tex_base_color, UV);
    vec4 tex_t_default_material_grid_n_value = texture(tex_t_default_material_grid_n, (((vec4(UV, 0.0, 1.0) / vec4(2)) / vec4(0.0500000007))).rg);
    ALBEDO = (tex_base_color_value).rgb;
    ROUGHNESS = clamp((tex_base_color_value).r, 0.0, 1.0);
    METALLIC = clamp(0.0, 0.0, 1.0);
    AO = clamp(1.0, 0.0, 1.0);
    NORMAL_MAP = ((vec4((tex_t_default_material_grid_n_value).rgb, 1.0) * vec4(vec3(0.300000012, 0.300000012, 1), 1.0))).rgb;
    EMISSION = vec3(0.0);
}
