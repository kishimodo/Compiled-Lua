/*!
 * @brief
 *  Default main() for compiled .exe outputs. Lives in its own TU so it
 *  doesn't get pulled when a custom-main host links against the static
 *  archive form of a compiled program.
 */

extern int RuntimeMain( int Argc, char **Argv );

int main( int Argc, char **Argv ) {
    return RuntimeMain( Argc, Argv );
}
