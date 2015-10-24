package hx2objc;

import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr;

using haxe.macro.Tools;

typedef ClassInfo = {
    @:optional var name: String;
    @:optional var pack: Array<String>;
    @:optional var fields: Array<FieldInfo>;
    @:optional var objc_name: String;
}

typedef FieldInfo = {
    @:optional var field: Field;
    @:optional var func: Function;
    @:optional var is_static: Bool;
    @:optional var is_public: Bool;
    @:optional var is_method: Bool;
}

class Macros {

    private static var called_once: Bool = false;
    private static var export_base_path: String = null;
    private static var export_base_name: String = null;
    private static var export_prefix: String = null;

    private static var classes: Map<String,ClassInfo>;
    private static var class_with_build_meta = null;

    private static var indent: Int = 0;
    private static var write_buffer: StringBuf;

        // Set the export path for Objective-C bridge
    macro static public function export(base_path:String, prefix:String = "HX"):Void {
        #if !(display || lint)
                // Initialize static properties
            if (base_path.length > 0) {
                if (base_path.charAt(0) != "/") {
                        // Configure base path
                    export_base_path = (Sys.getCwd() + "/" + base_path).split("//").join("/").split("app/../").join("/").split("//").join("/");
                    export_base_name = base_path.substr(base_path.lastIndexOf('/') + 1);
                    export_prefix = prefix;
                    classes = new Map<String,ClassInfo>();

                    log("Generate Objective-C (prefix=" + export_prefix + "):");
                    log("  " + export_base_path + ".h");
                    log("  " + export_base_path + ".mm");
                }
            }
        #end
    }

        // Generate the Objective-C++ bindings for the given class
    macro static public function generate(?objc_class_name:String):Array<Field> {
        if (export_base_path == null) return Context.getBuildFields();

            // Create class info
        var class_info:ClassInfo = {};

            // Compute class name
        if (objc_class_name == null) {
            objc_class_name = export_prefix + Context.getLocalClass().get().name;
        }
        class_info.objc_name = objc_class_name;
        class_info.name = Context.getLocalClass().get().name;
        class_info.pack = Context.getLocalClass().get().pack;

        var build_xml = '
        <files id="haxe">
            <compilerflag value="-fobjc-arc" />
            <file name="'+export_base_path+'.mm">
                <depend name="$'+'{HXCPP}/include/hx/Macros.h" />
                <depend name="$'+'{HXCPP}/include/hx/CFFI.h" />
            </file>
        </files>';
        if (class_with_build_meta == null) {
            class_with_build_meta = Context.getLocalClass().get();
        }
        class_with_build_meta.meta.remove(":buildXml");
        class_with_build_meta.meta.add(":buildXml", [macro $v{build_xml}], Context.currentPos());

            // Compute fields
        var fields = Context.getBuildFields();
        //return fields;
        class_info.fields = [];

            // Iterate over fields
        for (field in fields) {

                // Create field info
            var field_info:FieldInfo = {
                field: field,
                is_static: false,
                is_public: false,
                is_method: false
            };

                // Look for access modifiers
            for (acc in field.access) {
                if (acc == AStatic) {
                    field_info.is_static = true;
                }
                else if (acc == APublic) {
                    field_info.is_public = true;
                }
                else if (acc == APrivate) {
                    field_info.is_public = false;
                }
            }

                // Check if it is a method
            switch (field.kind) {
                case FFun(f):
                    field_info.is_method = true;
                    field_info.func = f;
                default:
            }

                // Add field
            class_info.fields.push(field_info);
        }

            // Add class info
        classes.set(class_info.name, class_info);

            // Dump Objective-C header
        dump_objc_header();

            // Dump Objective-C++ implementation
        dump_objcpp_implementation();

        return fields;
    }

    /// --- Dump header ---

    private static function dump_objc_header():Void {
            // Start writing
        start_writing();
        write_indented_line("//");
        write_indented_line("// " + export_base_name + ".h");
        write_indented_line("//");
        write_indented_line("// This file was generated from Haxe. Don't edit it's contents.");
        write_indented_line("//");
        write_line_break();

            // Import Foundation
        write_indented_line("#import <Foundation/Foundation.h>");
        write_line_break();

            // Write HXObject class interface
        write_indented_line("// Haxe object base class");
        write_indented_line("@interface HXObject : NSObject");
        write_indented_line("@end");
        write_line_break();

            // Iterate over classes
        for (name in classes.keys()) {
            var class_info = classes.get(name);

                // Write haxe full name
            write_indented_line("// " + class_info.name);

                // Write class interface
            write_indented_line("@interface " + class_info.objc_name + " : HXObject");
            write_line_break();

                // Write fields
            if (class_info.fields.length > 0) {
                for (field_info in class_info.fields) {
                        // Write method
                    if (field_info.is_method) {
                        write_indent();
                            // Constructor?
                        if (field_info.field.name == 'new') {
                                // Static or not?
                            if (field_info.is_static) {
                                write("+ ");
                            } else {
                                write("- ");
                            }

                            if (field_info.func.args.length > 0) {
                                    // Return type and name
                                write("(instancetype)initWith" + field_info.func.args[0].name.charAt(0).toUpperCase() + field_info.func.args[0].name.substr(1));
                            }
                            else {
                                write("(instancetype)init");
                            }
                        }
                        else {
                            write_indent();
                                // Static or not?
                            if (field_info.is_static) {
                                write("+ ");
                            } else {
                                write("- ");
                            }
                                // Return type
                            if (field_info.func.ret != null) {
                                write("(" + get_objc_type(field_info.func.ret) + ")");
                            } else {
                                write("(void)");
                            }
                                // Method name
                            write(camelize(field_info.field.name, false, "get"));
                        }
                            // Method arguments
                        var objc_arguments:Array<String> = [];
                        var i = 0;
                        for (arg in field_info.func.args) {
                            var entry = "(" + get_objc_type(arg.type) + ")" + camelize(arg.name);
                            if (i > 0) {
                                entry = camelize(arg.name) + ":" + entry;
                            }
                            objc_arguments.push(entry);
                            i++;
                        }
                        if (objc_arguments.length > 0) {
                            write(":" + objc_arguments.join(" "));
                        }

                        write(";");
                        write_line_break();
                        write_line_break();
                    }
                }
            }

                // Finish writing class interface
            write_indented_line("@end");
            write_line_break();
        }

            // End writing
        end_writing(export_base_path + ".h");
    }

    /// --- Dump implementation ---

    private static function dump_objcpp_implementation():Void {
            // Start writing
        start_writing();
        write_indented_line("//");
        write_indented_line("// " + export_base_name + ".mm");
        write_indented_line("//");
        write_indented_line("// This file was generated from Haxe. Don't edit it's contents.");
        write_indented_line("//");
        write_line_break();

            // Include HXCPP
        write_indented_line("#include <hxcpp.h>");
            // Include CFFI
        write_indented_line("#include <hx/CFFI.h>");
            // Include std::string, std::sstream, std::iostream
        write_indented_line("#include <string>");
        write_indented_line("#include <sstream>");
        write_indented_line("#include <iostream>");

        write_line_break();

            // Include Std (haxe)
        write_indented_line("#ifndef INCLUDED_Std");
        write_indented_line("#include <Std.h>");
        write_indented_line("#endif");

            // Include all used classes
        for (name in classes.keys()) {
            var class_info = classes.get(name);
            var define_name = class_info.name;
            var header_path = class_info.name;
            if (class_info.pack.length > 0) {
                define_name = class_info.pack.join("_") + "_" + define_name;
                header_path = class_info.pack.join("/") + "/" + header_path;
            }
            write_indented_line("#ifndef INCLUDED_" + define_name);
            write_indented_line("#include <" + header_path + ".h>");
            write_indented_line("#endif");
        }
            // Include ID holder
        write_indented_line("#ifndef INCLUDED_hx2objc_IDHolder");
        write_indented_line("#include <hx2objc/IDHolder.h>");
        write_indented_line("#endif");

            // Import header
        write_line_break();
        write_indented_line("#import \"" + export_base_name + ".h\"");
        write_line_break();

            // Write HXObject class interface
        write_indented_line("// Haxe object base class");
        write_indented_line("@interface HXObject ()");
        write_indented_line("- (instancetype)initWithHaxeInstance:(AutoGCRoot *)haxeInstance;");
        write_indented_line("@end");
        write_line_break();

            // Write HXObjcRef class interface
        write_indented_line("// Haxe object base class");
        write_indented_line("@interface HXObjcRef : NSObject");
        write_indented_line("+ (id)objectAtIndex:(NSInteger)index;");
        write_indented_line("+ (NSInteger)retainObject:(id)objcObject;");
        write_indented_line("+ (void)releaseObjectAtIndex:(NSInteger)objectIndex;");
        write_indented_line("@end");
        write_line_break();

            // Iterate over classes
        for (name in classes.keys()) {
            var class_info = classes.get(name);

                // Compute static class full name
            var static_full_name = class_info.name;
            if (class_info.pack.length > 0) {
                static_full_name = class_info.pack.join("::") + "::" + static_full_name;
            }

                // Write haxe full name
            write_indented_line("// " + class_info.name);

                // Write class implementation
            write_indented_line("@implementation " + class_info.objc_name);
            write_line_break();

                // Write fields
            if (class_info.fields.length > 0) {
                for (field_info in class_info.fields) {
                        // Write method
                    if (field_info.is_method) {
                        write_indent();
                            // Constructor?
                        if (field_info.field.name == 'new') {
                                // Static or not?
                            if (field_info.is_static) {
                                write("+ ");
                            } else {
                                write("- ");
                            }

                            if (field_info.func.args.length > 0) {
                                    // Return type and name
                                write("(instancetype)initWith" + field_info.func.args[0].name.charAt(0).toUpperCase() + field_info.func.args[0].name.substr(1));
                            }
                            else {
                                write("(instancetype)init");
                            }
                        }
                        else {
                            write_indent();
                                // Static or not?
                            if (field_info.is_static) {
                                write("+ ");
                            } else {
                                write("- ");
                            }
                                // Return type
                            if (field_info.func.ret != null) {
                                write("(" + get_objc_type(field_info.func.ret) + ")");
                            } else {
                                write("(void)");
                            }
                                // Method name
                            write(camelize(field_info.field.name, false, "get"));
                        }
                            // Method arguments
                        var objc_arguments:Array<String> = [];
                        var i = 0;
                        for (arg in field_info.func.args) {
                            var entry = "(" + get_objc_type(arg.type) + ")" + camelize(arg.name);
                            if (i > 0) {
                                entry = camelize(arg.name) + ":" + entry;
                            }
                            objc_arguments.push(entry);
                            i++;
                        }
                        if (objc_arguments.length > 0) {
                            write(":" + objc_arguments.join(" "));
                        }

                        write(" {");
                        write_line_break();
                        write_line_break();
                        indent++;

                            // Constructor specifics
                        if (field_info.field.name == 'new') {
                            write_indented_line("self = [super init];");
                            write_indented_line("if (self) {");
                            indent++;
                        }

                            // Method body
                        var i = 0;
                        for (arg in field_info.func.args) {
                            write_hx_var(arg.name, arg.type);
                            write_line_break();
                            i++;
                        }

                            // Call method code
                        var objc_ret = get_objc_type(field_info.func.ret);
                        write_indent();
                        if (field_info.field.name == "new") {
                            write("// new " + static_full_name.split("::").join(".") + "(");
                        } else {
                            write("// call " + field_info.field.name + "(");
                        }
                        var i = 0;
                        for (arg in field_info.func.args) {
                            if (i > 0) {
                                write(", ");
                            }
                            write(arg.name);
                            i++;
                        }
                        write(")");
                        write_line_break();
                        write_indent();
                        if (objc_ret != "void") {
                            if (objc_ret == "NSString *") {
                                write("String hx_ret = ");
                            } else if (objc_ret == "NSInteger") {
                                write("int hx_ret = ");
                            } else if (objc_ret == "double") {
                                write("Float hx_ret = ");
                            } else if (objc_ret == "BOOL") {
                                write("bool hx_ret = ");
                            } else {
                                write("Dynamic hx_ret = ");
                            }
                        }
                        if (field_info.is_static) {
                            write("::" + static_full_name + "_obj::" + field_info.field.name + "(");
                            var i = 0;
                            for (arg in field_info.func.args) {
                                if (i > 0) {
                                    write(", ");
                                }
                                write("hx_" + arg.name);
                                i++;
                            }
                            write(");");

                            write_line_break();

                            if (objc_ret != "void") {
                                write_line_break();
                                write_objc_var("ret", field_info.func.ret);
                                write_indented_line("return ret;");
                            }
                        } else {
                            if (field_info.field.name == "new") {
                                write("self.haxeInstance = new AutoGCRoot((value)::" + static_full_name + "_obj::__new(");
                            } else {
                                write("((::" + static_full_name + "_obj *)self.haxeInstance->get())->" + field_info.field.name + "(");
                            }
                            var i = 0;
                            for (arg in field_info.func.args) {
                                if (i > 0) {
                                    write(", ");
                                }
                                write("hx_" + arg.name);
                                i++;
                            }
                            if (field_info.field.name == "new") {
                                write(").GetPtr());");
                            } else {
                                write(");");
                            }

                            write_line_break();

                            if (objc_ret != "void") {
                                write_line_break();
                                write_objc_var("ret", field_info.func.ret);
                                write_indented_line("return ret;");
                            }
                        }

                            // Constructor specifics
                        if (field_info.field.name == 'new') {
                            indent--;
                            write_indented_line("}");
                            write_indented_line("return self;");
                        }

                        indent--;
                        write("}");
                        write_line_break();
                        write_line_break();
                    }
                }
            }

                // Finish writing class interface
            write_indented_line("@end");
            write_line_break();
        }

            // End writing
        end_writing(export_base_path + ".mm");
    }

    /// --- Specific write utils ---

    private static function write_hx_var(name:String, type:ComplexType):Void {
        var arg_type = get_objc_type(type);
        var hxcpp_type = get_hxcpp_type(type);
            write_indented_line("// hx_" + name + " ( " + arg_type + " => " + hxcpp_type + " )");
        if (arg_type == "NSString *") {
            write_indented_line("::String hx_" + name + " = String([" + camelize(name) + " UTF8String]);");
        } else if (arg_type == "NSInteger") {
            write_indented_line("int hx_" + name + " = (int)" + camelize(name) + ";");
        } else if (arg_type == "double") {
            write_indented_line("Float hx_" + name + " = (Float)" + camelize(name) + ";");
        } else if (arg_type == "BOOL") {
            write_indented_line("bool hx_" + name + " = (bool)" + camelize(name) + ";");
        } else if (arg_type == "id") {
            write_indented_line("Dynamic hx_" + name + " = null();");
            write_indented_line("if (" + camelize(name) + ") {");
            indent++;
            write_indented_line("if ([" + camelize(name) + " isKindOfClass:NSString.class]) hx_" + name + " = Dynamic([" + camelize(name) + " UTF8String]);");
            write_indented_line("else if ([" + camelize(name) + " isKindOfClass:NSNumber.class]) hx_" + name + " = Dynamic([" + camelize(name) + " doubleValue]);");
            write_indented_line("else if ([" + camelize(name) + " isKindOfClass:HXObject.class]) hx_" + name + " = Dynamic([" + camelize(name) + " haxeInstance]->get());");
            write_indented_line("else hx_" + name + " = ::hx2objc::IDHolder_obj::__new((int)[HXObjcRef retainObject:" + camelize(name) + "]);");
            indent--;
            write_indented_line("}");
        } else if (is_function_type(type)) {
            write_indented_line("int tmp_index_" + name + " = (int)[HXObjcRef retainObject:[" + camelize(name) + " copy]];");
            write_indented_line("Array< ::Dynamic > tmp_holder_" + name + " = Array_obj< ::Dynamic >::__new().Add(::hx2objc::IDHolder_obj::__new(tmp_index_" + name + "));");
            switch (type) {
                case TFunction(fn_args, fn_ret):
                    write_indented_line("HX_BEGIN_LOCAL_FUNC_S1(hx::LocalFunc, _Function_1_" + name + ", Array< ::Dynamic >, tmp_holder_" + name + ")");
                    write_indented_line("int __ArgCount() const { return " + fn_args.length + "; }");
                    var ret_hx_type = get_hxcpp_type(fn_ret);
                    var ret_objc_type = get_objc_type(fn_ret);
                    write_indent();
                    write(ret_hx_type + " run(");
                    var arg_i = 0;
                    for (arg in fn_args) {
                        if (arg_i > 0) {
                            write(", ");
                        }
                        write(get_hxcpp_type(arg) + " hx_arg" + arg_i);
                        arg_i++;
                    }
                    write(") {");
                    write_line_break();
                    indent++;
                    write_indented_line("{");
                    indent++;

                    var arg_i = 0;
                    for (arg in fn_args) {
                        write_objc_var("arg"+arg_i, arg);
                        arg_i++;
                    }

                    write_line_break();
                    write_indent();
                    write("// call " + camelize(name) + "(");
                    var arg_i = 0;
                    for (arg in fn_args) {
                        if (arg_i > 0) {
                            write(", ");
                        }
                        write(get_objc_type(arg));
                        arg_i++;
                    }
                    write(")");
                    write_line_break();
                    write_indented_line("id fn = [HXObjcRef objectAtIndex:(NSInteger)(int)tmp_holder_" + name + "->__get((int)0).StaticCast< ::hx2objc::IDHolder >()->instance_id];");
                    write_indent();
                    if (ret_objc_type != "void") {
                        if (ret_objc_type == "NSString *") {
                            write("NSString * ret = ");
                        } else if (ret_objc_type == "NSInteger") {
                            write("NSInteger ret = ");
                        } else if (ret_objc_type == "double") {
                            write("double ret = ");
                        } else if (ret_objc_type == "BOOL") {
                            write("BOOL ret = ");
                        } else {
                            write("id ret = ");
                        }
                    }
                    write("((" + arg_type + ")" + "fn)(");
                    var arg_i = 0;
                    for (arg in fn_args) {
                        if (arg_i > 0) {
                            write(", ");
                        }
                        write("arg"+arg_i);
                        arg_i++;
                    }
                    write(");");
                    write_line_break();
                    if (ret_objc_type != "void") {
                        write_line_break();
                        write_hx_var("ret", fn_ret);
                        write_indented_line("return hx_ret;");
                    }

                    indent--;
                    write_indented_line("}");
                    write_indented_line("return null();");
                    indent--;
                    write_indented_line("}");
                    if (ret_hx_type == "Void") {
                        write_indented_line("HX_END_LOCAL_FUNC" + fn_args.length + "((void))");
                    } else {
                        write_indented_line("HX_END_LOCAL_FUNC" + fn_args.length + "(return)");
                    }
                default:
            }

            write_indented_line("Dynamic hx_" + name + " = Dynamic(new _Function_1_" + name + "(tmp_holder_" + name + "));");
        } else {
            write_indented_line("Dynamic hx_" + name + " = null();");
        }
    }

    private static function write_objc_var(name:String, type:ComplexType):Void {
        var objc_type = get_objc_type(type);
        var hxcpp_type = get_hxcpp_type(type);
        write_indented_line("// " + camelize(name) + " ( " + objc_type + " <= " + hxcpp_type + " )");

        if (objc_type == "NSString *") {
            write_indented_line("NSString *" + camelize(name) + " = [[NSString alloc] initWithUTF8String:hx_" + name + ".__s];");
        } else if (objc_type == "NSInteger") {
            write_indented_line("NSInteger " + camelize(name) + " = (NSInteger)(int)hx_" + name + ";");
        } else if (objc_type == "double") {
            write_indented_line("double " + camelize(name) + " = (double)hx_" + name + ";");
        } else if (objc_type == "BOOL") {
            write_indented_line("BOOL " + camelize(name) + " = (BOOL)hx_" + name + ";");
        } else {
            write_indented_line("id " + camelize(name) + " = nil;");
            write_indented_line("if ((::Std_obj::is(hx_" + name + ", hx::ClassOf< ::String >()))) {");
            indent++;
            write_indented_line(camelize(name) + " = [[NSString alloc] initWithUTF8String:String(hx_" + name + ").__s];");
            indent--;
            write_indented_line("} else if ((::Std_obj::is(hx_" + name + ", hx::ClassOf< ::Int >()))) {");
            indent++;
            write_indented_line(camelize(name) + " = [NSNumber numberWithInteger:(NSInteger)(int)hx_" + name + "];");
            indent--;
            write_indented_line("} else if ((::Std_obj::is(hx_" + name + ", hx::ClassOf< ::Float >()))) {");
            indent++;
            write_indented_line(camelize(name) + " = [NSNumber numberWithDouble:(double)(Float)hx_" + name + "];");
            indent--;
            write_indented_line("} else if ((::Std_obj::is(hx_" + name + ", hx::ClassOf< ::Bool >()))) {");
            indent++;
            write_indented_line(camelize(name) + " = [NSNumber numberWithBool:(BOOL)(bool)hx_" + name + "];");
            indent--;
            write_indented_line("} else {");
            indent++;
            write_indented_line(camelize(name) + " = [[HXObject alloc] initWithHaxeInstance:new AutoGCRoot((value)(Dynamic(hx_" + name + ").GetPtr()))];");
            indent--;
            write_indented_line("}");
        }
    }

    /// --- Generic write utils ---

    private static function start_writing():Void {
        write_buffer = new StringBuf();
        indent = 0;
    }

    private static function write_indent():Void {
        var i = 0;
        while (i < indent) {
            write("    ");
            i++;
        }
    }

    private static function write_line_break():Void {
        write("\n");
    }

    private static function write_indented_line(content:String):Void {
        write_indent();
        write(content);
        write_line_break();
    }

    private static function write(str:String):Void {
        write_buffer.add(str);
    }

    private static function end_writing(file_path:String):Void {
        var dir_path = file_path.substr(0, file_path.lastIndexOf("/"));
        if (!sys.FileSystem.exists(dir_path)) {
            sys.FileSystem.createDirectory(dir_path);
        }
        sys.io.File.saveContent(file_path, write_buffer.toString());
        write_buffer = null;
    }

    /// --- String utils ---

    private static function camelize(str:String, first_letter_uppercase:Bool = false, ?skipped_prefix:String):String {
        var result = [];
        var i = 0;
        for (comp in str.split("_")) {
            if (comp.length > 0) {
                if (i > 0 || first_letter_uppercase) {
                    result.push(comp.charAt(0).toUpperCase());
                    result.push(comp.substr(1));
                } else {
                    result.push(comp);
                }
                i++;
            }
        }
        var result_str = result.join("");
        if (skipped_prefix != null && result_str.toLowerCase().substr(0, skipped_prefix.length) == skipped_prefix.toLowerCase()) {
            result_str = result_str.substr(skipped_prefix.length);
            if (result_str.length > 0) {
                if (first_letter_uppercase) {
                    result_str = result_str.charAt(0).toUpperCase() + result_str.substr(1);
                } else {
                    result_str = result_str.charAt(0).toLowerCase() + result_str.substr(1);
                }
            }
        }
        return result_str;
    }

    /// --- Logger ---

    private static function log(msg:Dynamic = ""):Void {
        Sys.stdout().writeString(msg + "\n");
    }

    /// --- ComplexType utils ---

    private static function is_function_type(?t:ComplexType):Bool {
        if (t == null) return false;

        switch (t) {
            case TFunction(fn_args, fn_ret):
                return true;
            default:
        }

        return false;
    }

    private static function get_hxcpp_type(?t:ComplexType):String {
        if (t == null) return "Dynamic";

        switch (t) {

            case TOptional(t):
                return get_hxcpp_type(t);

            case TPath(typep):
                var type_name = typep.name;
                var result;
                if (type_name == "Void") return "Void";
                else if (type_name == "Int") result = "Int";
                else if (type_name == "Float") result = "Float";
                else if (type_name == "Bool") result = "Bool";
                else if (type_name == "Array") result = "Array< ::Dynamic >";
                else if (type_name == "String") result = "::String";
                else if (type_name == "Dynamic") result = "Dynamic";
                else {
                    if (classes.exists(type_name)) {
                        var class_info = classes.get(type_name);
                        var result = class_info.name;
                        if (class_info.pack.length > 0) {
                            result = class_info.pack.join("::") + "::" + result;
                        }
                    } else {
                        result = "Dynamic";
                    }
                }
                return result;

            case TFunction(fn_args, fn_ret):
                return "Dynamic";

            default:
                return "Dynamic";
        }
    }

    private static function get_objc_type(?t:ComplexType):String {
        if (t == null) return "void";

        var type_name: String = null;
        var type_path: TypePath = null;
        var type_params: Array<String> = null;
        var type_signature: String = null;

        switch (t) {

            case TOptional(t):
                return get_objc_type(t);

            case TPath(typep):
                type_path = typep;
                if (type_path.params != null && type_path.params.length > 0) {
                    type_params = [];
                    for (param in type_path.params) {
                        switch(param) {
                            case TPType(tp):
                                type_params.push(get_objc_type(tp));
                            default:
                        }
                    }
                }
                type_name = typep.name;

            case TFunction(fn_args, fn_ret):
                type_name = "Function";
                var args = [];
                for (arg in fn_args) {
                    args.push(get_objc_type(arg));
                }
                type_signature = get_objc_type(fn_ret) + " (^)(" + args.join(", ") + ")";

            default:
                type_name = "void";
        }

        if (type_signature != null) {
            return type_signature;
        }

        var result = "id";
        if (type_name == "Void") return "void";
        else if (type_name == "Int") result = "NSInteger";
        else if (type_name == "Float") result = "double";
        else if (type_name == "Bool") result = "BOOL";
        else if (type_name == "Array") result = "NSArray *";
        else if (type_name == "String") result = "NSString *";
        else if (type_name == "Dynamic") result = "id";
        else {
            if (classes.exists(type_name)) {
                result = classes.get(type_name).objc_name + " *";
            } else {
                result = "id";
            }
        }

        return result;
    }
}
