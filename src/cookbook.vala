/*
 * Copyright (C) 2011-2014 Robert Ancell <robert.ancell@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later
 * version. See http://www.gnu.org/copyleft/gpl.html the full text of the
 * license.
 */

namespace Bake {

public errordomain CookbookError
{
    NO_RECIPE,
    NO_TOPLEVEL,
    INVALID_RECIPE,
}

public errordomain ConfigureError
{
    INVALID_ARGUMENT,
    UNKNOWN_OPTIONS,
    IO_ERROR,
}

public class Cookbook
{
    public signal void report_status (string text);
    public signal void report_debug (string text);

    private string original_dir;
    public string toplevel_dir;
    private List<BuildModule> modules;
    public Recipe current_recipe;
    public List<Option> options;
    private List<Template> templates;
    private List<Program> programs;
    private List<Library> libraries;
    private List<Data> datas;

    public Cookbook (string original_dir)
    {
        this.original_dir = original_dir;

        modules = new List<BuildModule> ();
        modules.append (new BZIPModule ());
        modules.append (new BZRModule ());
        modules.append (new DataModule ());
        modules.append (new DpkgModule ());
        modules.append (new GCCModule ());
        modules.append (new ClangModule ());
        modules.append (new GettextModule ());
        modules.append (new GHCModule ());
        modules.append (new GITModule ());
        modules.append (new GNOMEModule ());
        modules.append (new GSettingsModule ());
        modules.append (new GTKModule ());
        modules.append (new GZIPModule ());
        modules.append (new JavaModule ());
        modules.append (new LaunchpadModule ());
        modules.append (new MallardModule ());
        modules.append (new ManModule ());
        modules.append (new MonoModule ());
        modules.append (new PkgConfigModule ());
        modules.append (new PythonModule ());
        modules.append (new ReleaseModule ());
        modules.append (new RPMModule ());
        modules.append (new ScriptModule ());
        modules.append (new ValaModule ());
        modules.append (new XdgModule ());
        modules.append (new XZIPModule ());
    }

    public Recipe? find_toplevel (string original_dir, bool pretty_print) throws CookbookError
    {
        /* Find the toplevel */
        toplevel_dir = original_dir;
        var have_recipe = false;
        Recipe? toplevel = null;
        while (true)
        {
            var filename = Path.build_filename (toplevel_dir, "Recipe");
            try
            {
                toplevel = new Recipe.from_file (filename, pretty_print);
                if (toplevel.project_name != null)
                    break;
            }
            catch (Error e)
            {
                if (e is FileError.NOENT)
                {
                    if (have_recipe)
                        throw new CookbookError.NO_TOPLEVEL ("No toplevel recipe found.\nThe toplevel recipe file must specify the project name.\nThe last file checked was '%s'.".printf (get_relative_path (original_dir, filename)));
                    else
                        throw new CookbookError.NO_RECIPE ("No recipe found.\nTo build a project Bake requires a file called 'Recipe' in the current directory.");
                }
                else if (e is RecipeError)
                    throw new CookbookError.INVALID_RECIPE ("Recipe file '%s' is invalid.\n%s".printf (get_relative_path (original_dir, filename), e.message));
            }
            toplevel_dir = Path.get_dirname (toplevel_dir);
            have_recipe = true;
        }

        return toplevel;
    }

    public bool needs_configure
    {
        get
        {
            /* Must configure if options are not all set */
            foreach (var option in options)
                if (option.value == null && option.default == null)
                    return true;
            return false;
        }
    }

    public void configure (string[] args, Recipe conf_file) throws ConfigureError
    {
        var conf_data = "# This file is automatically generated by the Bake configure stage\n";
    
        var unknown_options = new List<string> ();
        for (var i = 0; i < args.length; i++)
        {
            var arg = args[i];
            var index = arg.index_of ("=");
            var id = "", value = "";
            if (index >= 0)
            {
                id = arg.substring (0, index).strip ();
                value = arg.substring (index + 1).strip ();
            }
            if (id == "" || value == "")
                throw new ConfigureError.INVALID_ARGUMENT ("Invalid configure argument '%s'. Arguments should be in the form name=value", arg);
            var option = get_option (id);
            if (option == null)
                unknown_options.append (id);
    
            var name = "options.%s".printf (id);
            conf_file.set_variable (name, value);
            conf_data += "%s=%s\n".printf (name, value);
        }
    
        if (unknown_options != null)
        {
            if (unknown_options.length () == 1)
                throw new ConfigureError.UNKNOWN_OPTIONS ("Unknown option '%s'", unknown_options.nth_data (0));
            else
            {
                var text = "Unknown options '%s'".printf (unknown_options.nth_data (0));
                for (var i = 1; i < unknown_options.length (); i++)
                    text += ", '%s'".printf (unknown_options.nth_data (i));
                throw new ConfigureError.UNKNOWN_OPTIONS ("%s", text);
            }
        }
    
        /* Write configuration */
        try
        {
            FileUtils.set_contents (Path.build_filename (toplevel_dir, "Recipe.conf"), conf_data);
        }
        catch (Error e)
        {
            throw new ConfigureError.IO_ERROR ("Failed to read back configuration: %s", e.message);
        }
    }

    public void unconfigure ()
    {
        FileUtils.unlink (Path.build_filename (toplevel_dir, "Recipe.conf"));
    }

    public Recipe? load_recipes (string filename, bool pretty_print = false, bool is_toplevel = true) throws Error
    {
        report_debug ("Loading %s".printf (get_relative_path (original_dir, filename)));

        var f = new Recipe.from_file (filename, pretty_print);

        /* Children can't be new toplevel recipes */
        if (!is_toplevel && f.project_name != null)
        {
            report_debug ("Ignoring toplevel recipe %s".printf (filename));
            return null;
        }

        /* Load children */
        var dir = Dir.open (f.dirname);
        while (true)
        {
            var child_dir = dir.read_name ();
            if (child_dir == null)
                 break;

            var child_filename = Path.build_filename (f.dirname, child_dir, "Recipe");
            if (FileUtils.test (child_filename, FileTest.EXISTS))
            {
                var c = load_recipes (child_filename, pretty_print, false);
                if (c != null)
                {
                    c.parent = f;
                    f.children.append (c);
                }
            }
        }

        /* Make rules recurse */
        foreach (var c in f.children)
        {
            f.build_rule.add_input ("%s/%%build".printf (Path.get_basename (c.dirname)));
            f.install_rule.add_input ("%s/%%install".printf (Path.get_basename (c.dirname)));
            f.uninstall_rule.add_input ("%s/%%uninstall".printf (Path.get_basename (c.dirname)));
            f.clean_rule.add_input ("%s/%%clean".printf (Path.get_basename (c.dirname)));
            f.test_rule.add_input ("%s/%%test".printf (Path.get_basename (c.dirname)));
        }

        return f;
    }

    public void setup (Recipe conf_file, Recipe toplevel)
    {
        find_objects (toplevel);

        /* Load options */
        make_built_in_option (conf_file, "install-directory", "Directory to install files to", "/");
        make_built_in_option (conf_file, "system-config-directory", "Directory to install system configuration", Path.build_filename ("/", "etc"));
        make_built_in_option (conf_file, "system-binary-directory", "Directory to install system binaries", Path.build_filename ("/", "sbin"));
        make_built_in_option (conf_file, "system-library-directory", "Directory to install system libraries", Path.build_filename ("/", "lib"));
        make_built_in_option (conf_file, "resource-directory", "Directory to install system libraries", Path.build_filename ("/", "usr"));
        make_built_in_option (conf_file, "binary-directory", "Directory to install binaries", "$(options.resource-directory)/bin");
        make_built_in_option (conf_file, "library-directory", "Directory to install libraries", "$(options.resource-directory)/lib");
        make_built_in_option (conf_file, "data-directory", "Directory to install data", "$(options.resource-directory)/share");
        make_built_in_option (conf_file, "include-directory", "Directory to install headers", "$(options.resource-directory)/include");
        make_built_in_option (conf_file, "project-data-directory", "Directory to install project files to", "$(options.data-directory)/%s".printf (toplevel.project_name));

        /* Make the configuration the toplevel file so everything inherits from it */
        conf_file.children.append (toplevel);
        toplevel.parent = conf_file;
    }

    public bool complete (Recipe toplevel) throws Error
    {
        foreach (var option in options)
            if (option.value == null && option.default != null)
                option.value = option.default;

        /* Find the recipe in the current directory */
        current_recipe = toplevel;
        while (current_recipe.dirname != original_dir)
        {
            foreach (var c in current_recipe.children)
            {
                var dir = original_dir + "/";
                if (dir.has_prefix (c.dirname + "/"))
                {
                    current_recipe = c;
                    break;
                }
            }
        }

        /* Generate implicit rules */
        generate_toplevel_rules (toplevel);

        /* Generate libraries first (as other things may depend on it) then the other rules */
        foreach (var template in templates)
            generate_template_rules (template);
        foreach (var library in libraries)
            generate_library_rules (library);
        foreach (var program in programs)
            generate_program_rules (program);
        foreach (var data in datas)
            generate_data_rules (data);

        /* Generate clean rule */
        generate_clean_rules (toplevel);

        /* Generate test rule */
        generate_test_rule ();

        /* Optimise */
        toplevel.targets = new HashTable<string, Rule> (str_hash, str_equal);
        var optimise_result = optimise (toplevel.targets, toplevel);

        recipe_complete (toplevel);
        foreach (var module in modules)
            module.rules_complete (toplevel);
            
        return optimise_result;
    }
    
    private Option? get_option (string id)
    {
        foreach (var option in options)
            if (option.id == id)
                return option;

        return null;
    }

    private void generate_toplevel_rules (Recipe recipe)
    {
        foreach (var module in modules)
            module.generate_toplevel_rules (recipe);
    }

    private void generate_template_rules (Template template) throws Error
    {
        var variables = template.get_variable ("variables").replace ("\n", " ");
        /* FIXME: Validate and expand the variables and escape suitable for command line */

        foreach (var entry in template.get_tagged_list ("files"))
        {
            if (!entry.is_allowed)
                continue;

            var file = entry.name;
            var template_file = "%s.template".printf (file);
            var rule = template.recipe.add_rule ();
            rule.add_input (template_file);
            rule.add_output (file);
            rule.add_status_command ("TEMPLATE %s".printf (file));
            var command = "@bake-template %s %s".printf (template_file, file);
            if (variables != null)
                command += " %s".printf (variables);
            rule.add_command (command);

            template.recipe.build_rule.add_input (file);
        }
    }

    private void generate_library_rules (Library library) throws Error
    {
        var recipe = library.recipe;

        var buildable_modules = new List<BuildModule> ();
        foreach (var module in modules)
        {
            if (module.can_generate_library_rules (library))
                buildable_modules.append (module);
        }

        if (buildable_modules.length () > 0)
            buildable_modules.nth_data (0).generate_library_rules (library);
        else
        {
            var rule = recipe.add_rule ();
            rule.add_output (library.name);
            rule.add_command ("@echo 'Unable to compile library %s:'".printf (library.id));
            rule.add_command ("@echo ' - No compiler found that matches source files'");
            rule.add_command ("@false");
            recipe.build_rule.add_input (library.name);
            recipe.add_install_rule (library.id, library.install_directory);
        }
    }

    private void generate_program_rules (Program program) throws Error
    {
        var recipe = program.recipe;

        var buildable_modules = new List<BuildModule> ();
        foreach (var module in modules)
        {
            if (module.can_generate_program_rules (program))
                buildable_modules.append (module);
        }

        if (buildable_modules.length () > 0)
        {
            buildable_modules.nth_data (0).generate_program_rules (program);

            foreach (var test_id in recipe.get_variable_children ("programs.%s.tests".printf (program.id)))
            {
                var command = "./%s".printf (program.name); // FIXME: Might not be called this for some compilers
                var args = recipe.get_variable ("programs.%s.tests.%s.args".printf (program.id, test_id));
                if (args != null)
                    command += " " + args;
                var results_filename = recipe.get_build_path ("%s.%s.test-results".printf (program.id, test_id));
                recipe.test_rule.add_output (results_filename);
                recipe.test_rule.add_status_command ("TEST %s.%s".printf (program.id, test_id));
                recipe.test_rule.add_command ("@bake-test run %s %s".printf (results_filename, command));
            }
        }
        else
        {
            var rule = recipe.add_rule ();
            rule.add_output (program.name);
            rule.add_command ("@echo 'Unable to compile program %s:'".printf (program.id));
            rule.add_command ("@echo ' - No compiler found that matches source files'");
            rule.add_command ("@false");
            recipe.build_rule.add_input (program.name);
            recipe.add_install_rule (program.name, program.install_directory);
        }
    }

    private void generate_data_rules (Data data) throws Error
    {
        foreach (var module in modules)
            module.generate_data_rules (data);
    }

    private void generate_clean_rules (Recipe recipe)
    {
        recipe.generate_clean_rule ();
        foreach (var child in recipe.children)
            generate_clean_rules (child);
    }

    private void generate_test_rule ()
    {
        var targets = new List<string> ();
        get_test_targets (current_recipe, ref targets);

        var command = "@bake-test check";
        foreach (var t in targets)
            command += " " + get_relative_path (current_recipe.dirname, t);

        current_recipe.test_rule.add_command (command);
    }

    private void get_test_targets (Recipe recipe, ref List<string> targets)
    {
        foreach (var input in recipe.test_rule.outputs)
            if (input != "%test")
                targets.append (Path.build_filename (recipe.dirname, input));
        foreach (var child in recipe.children)
            get_test_targets (child, ref targets);
    }

    private bool optimise (HashTable<string, Rule> targets, Recipe recipe)
    {
        var result = true;

        foreach (var rule in recipe.rules)
            foreach (var output in rule.outputs)
            {
                var path = Path.build_filename (recipe.dirname, output);
                if (targets.lookup (path) != null)
                {
                    report_status ("Output %s is defined in multiple locations".printf (get_relative_path (original_dir, path)));
                    result = false;
                }
                targets.insert (path, rule);
            }

        foreach (var r in recipe.children)
            if (!optimise (targets, r))
                result = false;

        return result;
    }

    private void find_objects (Recipe recipe)
    {
        options = new List<Option> ();
        foreach (var id in recipe.get_variable_children ("options"))
        {
            var option = new Option (recipe, id);
            options.append (option);
        }
        templates = new List<Template> ();
        foreach (var id in recipe.get_variable_children ("templates"))
        {
            var template = new Template (recipe, id);
            templates.append (template);
        }
        programs = new List<Program> ();
        foreach (var id in recipe.get_variable_children ("programs"))
        {
            var program = new Program (recipe, id);
            programs.append (program);
        }
        libraries = new List<Library> ();
        foreach (var id in recipe.get_variable_children ("libraries"))
        {
            var library = new Library (recipe, id);
            libraries.append (library);
        }
        datas = new List<Data> ();
        foreach (var id in recipe.get_variable_children ("data"))
        {
            var data = new Data (recipe, id);
            datas.append (data);
        }

        foreach (var child in recipe.children)
            find_objects (child);
    }

    private Option make_built_in_option (Recipe conf_file, string id, string description, string default)
    {
        conf_file.set_variable ("options.%s.description".printf (id), description);
        conf_file.set_variable ("options.%s.default".printf (id), default);
        var option = new Option (conf_file, id);
        options.append (option);

        return option;
    }

    private void recipe_complete (Recipe recipe)
    {
        foreach (var module in modules)
            module.recipe_complete (recipe);

        foreach (var child in recipe.children)
            recipe_complete (child);
    }
}

}
