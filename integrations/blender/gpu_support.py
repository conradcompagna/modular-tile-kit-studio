"""Optional GPU drawing imports; headless use has no drawing requirement."""
try:
    import gpu
    from gpu_extras.batch import batch_for_shader
except Exception:
    gpu = None
    batch_for_shader = None
