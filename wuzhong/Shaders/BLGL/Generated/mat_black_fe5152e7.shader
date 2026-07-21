shader_type spatial;
render_mode shading_model_pbr, cull_back;


void fragment() {
    ALBEDO = vec3(0);
    ROUGHNESS = clamp(0, 0.0, 1.0);
    METALLIC = clamp(0.0, 0.0, 1.0);
    AO = clamp(1.0, 0.0, 1.0);
    EMISSION = vec3(0.0);
}
