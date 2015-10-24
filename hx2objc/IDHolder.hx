package hx2objc;

#if (cpp && (ios || mac || tvos))
@:cppFileCode('extern "C" void _hx_objc_release_id(int instance_id);')
@:keep class IDHolder {

    public var instance_id:Int;

    public function new(_id:Int) {
        instance_id = _id;
        cpp.vm.Gc.setFinalizer(this, cpp.Function.fromStaticFunction(destroy));
    }

    @:void public static function destroy(id_holder:IDHolder):Void {
        untyped __cpp__('_hx_objc_release_id(id_holder->instance_id)');
    }
}
#else
class IDHolder {

    public var instance_id:Int;

    public function new(_id:Int) {
        instance_id = _id;
    }
}
#end
