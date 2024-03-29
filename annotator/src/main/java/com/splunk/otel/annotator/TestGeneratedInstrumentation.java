package com.splunk.otel.annotator;

import com.github.javaparser.StaticJavaParser;
import com.github.javaparser.ast.body.ClassOrInterfaceDeclaration;
import com.github.javaparser.ast.visitor.VoidVisitorAdapter;
// import com.google.common.base.Strings;
import java.io.File;
import java.io.IOException;

public class TestGeneratedInstrumentation {


	public static void listClasses(File projectDir) {
		new DirExplorerInstrumented((level, path, file) -> path.endsWith(".java"), (level, path, file) -> {
			System.out.println(path);
			System.out.println("=================================================================");
			System.out.println("=================================================================");
			try {
				new VoidVisitorAdapter<Object>() {
					@Override
					public void visit(ClassOrInterfaceDeclaration n, Object arg) {
						super.visit(n, arg);
						System.out.println(" * " + n.getName());
					}
				}.visit(StaticJavaParser.parse(file), null);
				System.out.println(); // empty line
			} catch (IOException e) {
				new RuntimeException(e);
			}
		}).explore(projectDir);
	}
	
	  public static void main(String[] args) {
	        File projectDir = new File("src/main/java");
	        listClasses(projectDir);
	    }
}

